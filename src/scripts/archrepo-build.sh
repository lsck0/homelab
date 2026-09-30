#!/usr/bin/env bash
# build arch-dotfiles' mirror/packages.conf into the signed lsck0 pacman repo
#
# Runs as root in a fresh archlinux:base-devel container on vm-119 (archbuild.service):
#   /repo              served tree on the nas: x86_64/ (packages, db), status.txt, status.json, .state/
#   /cache             persistent build state on the vm disk: pacman cache, sources, cargo and go caches
#   /public            the builder's status page: build.log, logs/<base>.log, status.txt
#   /run/signing.asc   armored secret signing key
#
# Every package is served as lsck0-<name> with provides=<name>=<version> and conflicts=<name>.
# Recipes are built unmodified and the finished package is repacked under the new name: renaming
# inside the PKGBUILD breaks every recipe that uses $pkgname as a path (cd "$pkgname-$pkgver").
# The repack also turns pkgrel 1 into 1.<n>, n counting the builds of that base, so a rebuild never
# reuses a file name a client may have cached with other contents.
#
# A base is rebuilt when its recipe hash changes (aur commit, crate or module version, local
# PKGBUILD, a -git source's upstream head via pkgver()) or its last build is FULL_REBUILD_DAYS old.
# A new package enters the repo only once built, repacked and signed; old files are deleted only
# after the db that replaced them is published. Crash-only: all state is per base, a killed run is
# picked up by the next one.
set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# CONSTANTS
REPO=lsck0
PREFIX=lsck0-
REPO_DIR=/repo/x86_64
STATE_DIR=/repo/.state
CACHE=/cache
PUBLIC=/public
SIGNING_KEY_FILE=/run/signing.asc
# ssh push to the always-on dmz mirror after each run; empty disables it
PUSH_TARGET=${ARCHBUILD_PUSH_TARGET:-}
PUSH_KEY_FILE=/run/push-key
SOURCE=${ARCHBUILD_SOURCE:?git url or directory of arch-dotfiles}
REF=${ARCHBUILD_REF:-master}
BUILDER=builder
# the uid every writing container on the nas uses
BUILDER_UID=1000
# soname bumps on a rolling distro break old builds without a version change
FULL_REBUILD_DAYS=14
# per recipe, so one hung build cannot eat the night
BUILD_TIMEOUT=3h
FETCH_TIMEOUT=15m
HTTP_TIMEOUT_S=60
# bound on the depth of aur dependency chains
RESOLVE_ROUNDS_MAX=16
# names per aur rpc request
RPC_BATCH=100
CACHE_KEEP_DAYS=30
# part of every rebuild key: bump it when repack changes what a published package contains
REPACK_VERSION=2
CHAOTIC_KEY=3056513887B78AEB
CHAOTIC_URL=https://cdn-mirror.chaotic.cx/chaotic-aur
AUR_URL=https://aur.archlinux.org
USER_AGENT="lsck0-archbuild (https://github.com/lsck0/arch-dotfiles)"

# -----------------------------------------------------------------------------
# STATE
declare -A kind=() argument=() listed=() names=() deps=() provider=() failed=() repo_has=() db_file=() looked_up=()
bases=()
order=()
aur_wanted=()
built=()
# prune only when every base is known, a transient fetch error must not delete packages
resolve_complete=1
KEY=
DOTFILES=
COMMIT=
BASELINE_PACKAGES=

# -----------------------------------------------------------------------------
# HELPERS
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

fail() {
  failed[$1]=$2
  log "FAIL $1: $2"
}

http() { curl -fsSL --max-time "$HTTP_TIMEOUT_S" --retry 3 -A "$USER_AGENT" "$@"; }

# a command prefix, not a function: timeout runs it
AS_BUILDER=(sudo -u "$BUILDER" -H env CARGO_HOME="$CACHE/cargo" CARGO_TARGET_ROOT="$CACHE/cargo-target"
  GOPATH="$CACHE/go" GOMODCACHE="$CACHE/go/mod" GOCACHE="$CACHE/go/build")

# .SRCINFO values of one key, arch-specific ones included
srcinfo_get() {
  awk -v k="$2" '{ sub(/^[ \t]+/, "") } ($1 == k || $1 == k "_x86_64") && $2 == "=" { print $3 }' "$1"
}

state_get() { sed -n "s/^$2=//p" "$STATE_DIR/$1" 2>/dev/null || true; }

state_set() {
  local base=$1 key=$2 build=$3 pkgnames=$4
  printf 'key=%s\nbuild=%s\nbuilt=%s\nnames=%s\n' "$key" "$build" "$(date +%s)" "$pkgnames" > "$STATE_DIR/.$base.tmp"
  mv -f "$STATE_DIR/.$base.tmp" "$STATE_DIR/$base"
}

# copy then rename, a reader never sees half a file
put() {
  cp "$1" "$2/.${3:-$(basename "$1")}.tmp"
  mv -f "$2/.${3:-$(basename "$1")}.tmp" "$2/${3:-$(basename "$1")}"
}

sign() { gpg --batch --yes --detach-sign --no-armor -u "$KEY" -o "$1.sig" "$1"; }

# -----------------------------------------------------------------------------
# REPO
load_db_index() {
  local name file
  db_file=()
  while read -r name file; do
    db_file[$name]=$file
  done < <(bsdtar -xOf "$CACHE/db/$REPO.db.tar.gz" 2>/dev/null \
    | awk '/^%FILENAME%$/ { getline f } /^%NAME%$/ { getline n; print n, f }')
}

db_publish() {
  local f
  for f in "$REPO.db.tar.gz" "$REPO.files.tar.gz"; do
    sign "$CACHE/db/$f"
    put "$CACHE/db/$f" "$REPO_DIR"
    put "$CACHE/db/$f.sig" "$REPO_DIR"
  done
  ln -sfn "$REPO.db.tar.gz" "$REPO_DIR/$REPO.db"
  ln -sfn "$REPO.db.tar.gz.sig" "$REPO_DIR/$REPO.db.sig"
  ln -sfn "$REPO.files.tar.gz" "$REPO_DIR/$REPO.files"
  ln -sfn "$REPO.files.tar.gz.sig" "$REPO_DIR/$REPO.files.sig"
  load_db_index
}

# the served db is the truth, the staging copy is rebuilt from it every run
db_stage() {
  local f
  mkdir -p "$REPO_DIR" "$STATE_DIR" "$CACHE/db"
  for f in "$REPO.db.tar.gz" "$REPO.files.tar.gz"; do
    if [ -f "$REPO_DIR/$f" ]; then
      cp "$REPO_DIR/$f" "$CACHE/db/$f"
    else
      bsdtar -czf "$CACHE/db/$f" --files-from /dev/null
    fi
  done
  db_publish
}

# rename to lsck0-<name>, rel 1 -> 1.<build>; prints the signed package path
repack() {
  local package=$1 build=$2 dir=$CACHE/repack name base version arch release file
  rm -rf "$dir"
  mkdir -p "$dir" "$CACHE/stage"
  bsdtar -xpf "$package" -C "$dir" || return 1
  name=$(sed -n 's/^pkgname = //p' "$dir/.PKGINFO")
  base=$(sed -n 's/^pkgbase = //p' "$dir/.PKGINFO")
  version=$(sed -n 's/^pkgver = //p' "$dir/.PKGINFO")
  arch=$(sed -n 's/^arch = //p' "$dir/.PKGINFO")
  [ -n "$name" ] && [ -n "$version" ] && [ -n "$arch" ] || return 1
  release=${version##*-}
  version=${version%-*}
  sed -i -e "s/^pkgname = .*/pkgname = $PREFIX$name/" -e "s/^pkgbase = .*/pkgbase = $PREFIX${base:-$name}/" \
    -e "s/^pkgver = .*/pkgver = $version-${release%%.*}.$build/" "$dir/.PKGINFO" "$dir/.BUILDINFO"
  # .PKGINFO spells it conflict, conflicts is silently ignored
  printf 'provides = %s=%s\nconflict = %s\n' "$name" "$version" "$name" >> "$dir/.PKGINFO"
  file=$CACHE/stage/$PREFIX$name-$version-${release%%.*}.$build-$arch.pkg.tar.zst
  # same file list, order and mtree options as makepkg's create_package
  (
    cd "$dir"
    shopt -s dotglob globstar
    export LC_COLLATE=C
    printf '%s\0' **/* | bsdtar -cnf - --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --null --files-from - --exclude .MTREE | gzip -c -f -n > .MTREE
    printf '%s\0' **/* | bsdtar --no-fflags -cnf - --null --files-from - | zstd -c -T0 -q > "$file"
  ) || return 1
  sign "$file" || return 1
  gpg --batch --verify "$file.sig" "$file" 2>/dev/null || return 1
  echo "$file"
}

publish() {
  local file served=()
  for file; do
    put "$file" "$REPO_DIR"
    put "$file.sig" "$REPO_DIR"
    served+=("$REPO_DIR/$(basename "$file")")
  done
  repo-add -q "$CACHE/db/$REPO.db.tar.gz" "${served[@]}" || return 1
  db_publish
  pacman -Sy --noconfirm >/dev/null
}

# -----------------------------------------------------------------------------
# SETUP
setup_builder() {
  id "$BUILDER" >/dev/null 2>&1 || useradd -m -u "$BUILDER_UID" "$BUILDER"
  echo "$BUILDER ALL=(root) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
  # regenerated every run; a stale recipe would linger as a base that is no longer wanted
  rm -rf "$CACHE/build" "$CACHE/out" "$CACHE/recipes"
  mkdir -p "$CACHE"/{pacman,src,build,aur,recipes,out,stage,cargo,cargo-target,go} "$PUBLIC/logs"
  chown "$BUILDER:" "$CACHE"/{src,build,recipes,out,cargo,cargo-target,go}
}

setup_key() {
  gpg --batch --import "$SIGNING_KEY_FILE" 2>/dev/null
  KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  [ -n "$KEY" ] || { log "no signing key in $SIGNING_KEY_FILE"; exit 1; }
  cat > /etc/makepkg.conf.d/archbuild.conf <<EOF
MAKEFLAGS="-j$(nproc)"
BUILDDIR=$CACHE/build
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
PACKAGER="$(gpg --with-colons --list-keys "$KEY" | awk -F: '$1 == "uid" { print $10; exit }')"
EOF
}

setup_pacman() {
  pacman-key --init >/dev/null 2>&1
  pacman-key --populate archlinux >/dev/null 2>&1
  gpg --armor --export "$KEY" > "$CACHE/signing.pub"
  pacman-key --add "$CACHE/signing.pub" >/dev/null 2>&1
  pacman-key --lsign-key "$KEY" >/dev/null 2>&1
  timeout 5m pacman-key --recv-key "$CHAOTIC_KEY" --keyserver keyserver.ubuntu.com >/dev/null 2>&1
  pacman-key --lsign-key "$CHAOTIC_KEY" >/dev/null 2>&1
  pacman -Sy >/dev/null
  pacman -U --noconfirm "$CHAOTIC_URL/chaotic-keyring.pkg.tar.zst" "$CHAOTIC_URL/chaotic-mirrorlist.pkg.tar.zst" >/dev/null
  # the image strips docs and locales, a build dependency must install whole
  sed -i -e '/^NoExtract/d' -e "s|^#\?CacheDir.*|CacheDir = $CACHE/pacman/|" /etc/pacman.conf
  cat >> /etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist

[$REPO]
SigLevel = Required
Server = file://$REPO_DIR
EOF
  pacman -Syu --noconfirm --needed git jq expac rsync openssh >/dev/null
  git config --global --add safe.directory '*'
  BASELINE_PACKAGES=$(pacman -Qq)
}

fetch_dotfiles() {
  if [ -d "$SOURCE" ]; then
    DOTFILES=$SOURCE
    COMMIT=$(git -C "$SOURCE" rev-parse --short HEAD 2>/dev/null || echo "working tree")
    return 0
  fi
  DOTFILES=$CACHE/dotfiles
  if [ -d "$DOTFILES/.git" ]; then
    timeout "$FETCH_TIMEOUT" git -C "$DOTFILES" fetch -q --depth 1 origin "$REF"
    git -C "$DOTFILES" reset -q --hard FETCH_HEAD
  else
    rm -rf "$DOTFILES"
    timeout "$FETCH_TIMEOUT" git clone -q --depth 1 --branch "$REF" "$SOURCE" "$DOTFILES"
  fi
  COMMIT=$(git -C "$DOTFILES" rev-parse --short HEAD)
}

# names and provides of every official and chaotic package
load_repo_index() {
  local repo name provides
  while read -r repo name provides; do
    [ "$repo" = "$REPO" ] && continue
    repo_has[$name]=1
    for provides in $provides; do
      repo_has[${provides%%=*}]=1
    done
  done < <(expac -S -l ' ' '%r %n %S')
}

# -----------------------------------------------------------------------------
# RECIPES
depends_helper() {
  cat <<'EOF'

# runtime libraries the binaries link, resolved while the build deps are still installed
_depends_from_libraries() {
  depends=($(find "$pkgdir/usr/bin" -type f -exec env -u LD_PRELOAD ldd {} + 2>/dev/null \
    | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' | sort -u | xargs -r pacman -Qqo | sort -u))
}
EOF
}

recipe_aur() {
  local base=$1 dir=$2 clone=$CACHE/aur/$1
  if [ -d "$clone/.git" ]; then
    timeout "$FETCH_TIMEOUT" git -C "$clone" fetch -q origin master || return 1
    git -C "$clone" reset -q --hard FETCH_HEAD || return 1
  else
    rm -rf "$clone"
    timeout "$FETCH_TIMEOUT" git clone -q "$AUR_URL/$base.git" "$clone" || return 1
  fi
  git -C "$clone" archive HEAD | tar -x -C "$dir"
}

recipe_cargo() {
  local name=$1 dir=$2 version description
  version=$(http "https://crates.io/api/v1/crates/$name" | jq -er '.crate.max_stable_version // .crate.max_version') || return 1
  description=$(http "https://crates.io/api/v1/crates/$name/$version" \
    | jq -r '.version | "pkgdesc=\(.description // "" | gsub("\\s+"; " ") | @sh)\nlicense=(\(.license // "custom" | @sh))"') || return 1
  {
    printf 'pkgname=%s\n_crate=%s\n_version=%s\npkgver=%s\n%s\n' "$name" "$name" "$version" "${version//-/_}" "$description"
    cat <<'EOF'
pkgrel=1
arch=(x86_64)
url="https://crates.io/crates/$_crate"
# native deps most crates with a sys crate need
makedepends=(rust pkgconf openssl cmake)
options=(!lto !debug)

build() {
  CARGO_TARGET_DIR="$CARGO_TARGET_ROOT/$_crate" cargo install --locked --no-track \
    --root "$srcdir/root" --version "=$_version" "$_crate"
}

package() {
  install -Dm755 -t "$pkgdir/usr/bin" "$srcdir"/root/bin/*
  _depends_from_libraries
}
EOF
    depends_helper
  } > "$dir/PKGBUILD"
}

# the proxy wants upper case letters as !lower
go_escape() { sed 's/[A-Z]/!\L&/g' <<<"$1"; }

recipe_go() {
  local name=$1 spec=$2 dir=$3 path version prefix
  [ -n "$spec" ] || return 1
  path=${spec%@*}
  version=latest
  [ "$path" != "$spec" ] && version=${spec##*@}
  # the module is the longest prefix of the package path the proxy knows
  if [ "$version" = latest ]; then
    version=
    prefix=$path
    while [ -z "$version" ]; do
      version=$(http "https://proxy.golang.org/$(go_escape "$prefix")/@latest" 2>/dev/null | jq -r '.Version // empty') || true
      [ -n "$version" ] && break
      [[ $prefix == */* ]] || return 1
      prefix=${prefix%/*}
    done
  fi
  {
    printf 'pkgname=%s\n_path=%s\n_version=%s\npkgver=%s\n' "$name" "$path" "$version" "$(sed 's/^v//; s/-/_/g' <<<"$version")"
    cat <<'EOF'
pkgrel=1
pkgdesc="go install $_path"
arch=(x86_64)
url="https://$_path"
license=(custom)
makedepends=(go)
options=(!lto !debug)

build() {
  export CGO_CPPFLAGS="$CPPFLAGS" CGO_CFLAGS="$CFLAGS" CGO_CXXFLAGS="$CXXFLAGS" CGO_LDFLAGS="$LDFLAGS"
  export GOFLAGS="-buildmode=pie -trimpath -modcacherw"
  GOBIN="$srcdir/bin" go install "$_path@$_version"
}

package() {
  install -Dm755 -t "$pkgdir/usr/bin" "$srcdir"/bin/*
  _depends_from_libraries
}
EOF
    depends_helper
  } > "$dir/PKGBUILD"
}

recipe_local() {
  local name=$1 dir=$2
  [ -f "$DOTFILES/mirror/pkgbuilds/$name/PKGBUILD" ] || return 1
  cp -r "$DOTFILES/mirror/pkgbuilds/$name/." "$dir/"
}

# recipe dir with an unprefixed PKGBUILD and its .SRCINFO; records names, provides and deps
materialize() {
  local base=$1 dir=$CACHE/recipes/$1 name
  rm -rf "$dir"
  mkdir -p "$dir"
  case ${kind[$base]} in
    aur) recipe_aur "$base" "$dir" ;;
    cargo) recipe_cargo "$base" "$dir" ;;
    go) recipe_go "$base" "${argument[$base]}" "$dir" ;;
    local) recipe_local "$base" "$dir" ;;
  esac || { fail "$base" "fetching the recipe"; resolve_complete=0; return 1; }
  chown -R "$BUILDER:" "$dir"
  if [ "${kind[$base]}" != aur ]; then
    (cd "$dir" && "${AS_BUILDER[@]}" makepkg --printsrcinfo > .SRCINFO) || { fail "$base" "invalid PKGBUILD"; return 1; }
  fi
  names[$base]=$(srcinfo_get "$dir/.SRCINFO" pkgname | xargs)
  deps[$base]=$(
    { srcinfo_get "$dir/.SRCINFO" depends; srcinfo_get "$dir/.SRCINFO" makedepends; } | sed 's/[<>=].*//' | sort -u | xargs
  )
  for name in ${names[$base]} $(srcinfo_get "$dir/.SRCINFO" provides | sed 's/=.*//'); do
    provider[$name]=$base
  done
}

add_base() {
  [ -n "${kind[$1]:-}" ] && return 0
  kind[$1]=$2
  argument[$1]=${3:-}
  bases+=("$1")
  materialize "$1" || true
}

# -----------------------------------------------------------------------------
# RESOLVE
read_conf() {
  local conf=$DOTFILES/mirror/packages.conf line name source spec
  [ -f "$conf" ] || { log "no $conf"; exit 1; }
  while IFS= read -r line; do
    line=${line%%#*}
    read -r name source spec _ <<<"$line" || true
    [ -n "${name:-}" ] || continue
    listed[$name]=1
    case $source in
      aur) aur_wanted+=("$name") ;;
      cargo | go | local) add_base "$name" "$source" "${spec:-}" ;;
      *) fail "$name" "unknown source '$source'"; resolve_complete=0 ;;
    esac
  done < "$conf"
}

# prints "name base" for every name the aur has
aur_bases() {
  local names_batch=("$@") i name args
  for (( i = 0; i < ${#names_batch[@]}; i += RPC_BATCH )); do
    args=()
    for name in "${names_batch[@]:i:RPC_BATCH}"; do
      args+=(--data-urlencode "arg[]=$name")
    done
    http "$AUR_URL/rpc/v5/info" "${args[@]}" | jq -r '.results[] | "\(.Name) \(.PackageBase)"' || return 1
  done
}

aur_base_providing() {
  http "$AUR_URL/rpc/v5/search/$(jq -rn --arg n "$1" '$n | @uri')?by=provides" \
    | jq -r --arg n "$1" '[.results[] | select(.Name == $n)] + (.results | sort_by(-.NumVotes)) | .[0].PackageBase // empty'
}

unsatisfied_deps() {
  local base dep
  for base; do
    for dep in ${deps[$base]:-}; do
      [ -n "${repo_has[$dep]:-}${provider[$dep]:-}${looked_up[$dep]:-}" ] || echo "$dep"
    done
  done | sort -u
}

# listed aur names plus every dependency neither the repos nor another base satisfies
resolve() {
  local round pending name base lines new
  declare -A found
  mapfile -t pending < <({ printf '%s\n' "${aur_wanted[@]}"; unsatisfied_deps "${bases[@]}"; } | sort -u | sed '/^$/d')
  for (( round = 0; round < RESOLVE_ROUNDS_MAX && ${#pending[@]} > 0; round++ )); do
    found=()
    lines=$(aur_bases "${pending[@]}") || { log "aur rpc failed"; resolve_complete=0; return 0; }
    while read -r name base; do
      [ -n "$name" ] && found[$name]=$base
    done <<<"$lines"
    new=()
    for name in "${pending[@]}"; do
      looked_up[$name]=1
      base=${found[$name]:-}
      [ -n "$base" ] || [ -n "${listed[$name]:-}" ] || base=$(aur_base_providing "$name" || true)
      if [ -z "$base" ]; then
        [ -n "${listed[$name]:-}" ] && { fail "$name" "not in the aur"; resolve_complete=0; }
        continue
      fi
      [ -n "${kind[$base]:-}" ] || { add_base "$base" aur; new+=("$base"); }
    done
    mapfile -t pending < <(unsatisfied_deps "${new[@]}")
  done
  (( ${#pending[@]} == 0 )) || { log "dependency depth exceeds $RESOLVE_ROUNDS_MAX"; resolve_complete=0; }
}

# dependencies first into order; a base whose dependency nothing provides fails here
plan() {
  local base dep edges=()
  for base in "${bases[@]}"; do
    edges+=("$base $base")
    for dep in ${deps[$base]:-}; do
      if [ -n "${provider[$dep]:-}" ]; then
        [ "${provider[$dep]}" = "$base" ] || edges+=("${provider[$dep]} $base")
      elif [ -z "${repo_has[$dep]:-}" ] && [ -z "${failed[$base]:-}" ]; then
        fail "$base" "nothing provides $dep"
      fi
    done
  done
  mapfile -t order < <(printf '%s\n' "${edges[@]}" | tsort 2>/dev/null)
}

# -----------------------------------------------------------------------------
# BUILD
is_vcs() { grep -Eq '^\s*source(_x86_64)? = ([^ ]*::)?(git|hg|svn|bzr|fossil)\+' "$1/.SRCINFO"; }

recipe_key() {
  { echo "repack $REPACK_VERSION"; cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } \
    | sha256sum | cut -d' ' -f1
}

is_current() {
  local base=$1 key=$2 name built_at
  [ "$key" = "$(state_get "$base" key)" ] || return 1
  built_at=$(state_get "$base" built)
  (( $(date +%s) - ${built_at:-0} < FULL_REBUILD_DAYS * 86400 )) || return 1
  for name in $(state_get "$base" names); do
    [ -n "${db_file[$name]:-}" ] || return 1
  done
}

remove_build_deps() {
  local extra
  extra=$(comm -13 <(sort <<<"$BASELINE_PACKAGES") <(pacman -Qq | sort))
  [ -z "$extra" ] || pacman -Rdd --noconfirm $extra >/dev/null 2>&1 || true
}

build_base() {
  local base=$1 dir=$CACHE/recipes/$1 log=$PUBLIC/logs/$1.log out=$CACHE/out/$1 key build package file files=() pkgnames=()
  : > "$log"
  # per base: recipes name different tarballs alike (tree-sitter-json-0.24.8.tar.gz from github and pypi)
  install -d -o "$BUILDER" "$CACHE/src/$base"
  # pkgver() writes upstream's head into the PKGBUILD, which moves the key
  if is_vcs "$dir"; then
    (cd "$dir" && timeout -k 1m "$FETCH_TIMEOUT" "${AS_BUILDER[@]}" SRCDEST="$CACHE/src/$base" makepkg -od --noprepare --skipinteg --noconfirm) >> "$log" 2>&1 \
      || log "$base: upstream version check failed, building from the recipe as is"
  fi
  key=$(recipe_key "$dir")
  is_current "$base" "$key" && return 0
  build=$(( $(state_get "$base" build || true) + 1 ))
  log "$base: building (build $build)"
  srcinfo_get "$dir/.SRCINFO" validpgpkeys | xargs -r timeout 2m sudo -u "$BUILDER" -H \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys >> "$log" 2>&1 || true
  rm -rf "$out"
  install -d -o "$BUILDER" "$out"
  if ! (cd "$dir" && timeout -k 5m "$BUILD_TIMEOUT" "${AS_BUILDER[@]}" SRCDEST="$CACHE/src/$base" PKGDEST="$out" makepkg -srfc --noconfirm --nocheck) >> "$log" 2>&1; then
    remove_build_deps
    fail "$base" "build failed, logs/$base.log"
    return 1
  fi
  remove_build_deps
  rm -f "$CACHE"/stage/*
  for package in "$out"/*.pkg.tar.zst; do
    file=$(repack "$package" "$build") || { fail "$base" "repack or signing failed"; return 1; }
    files+=("$file")
    pkgnames+=("$PREFIX$(bsdtar -xOf "$package" .PKGINFO | sed -n 's/^pkgname = //p')")
  done
  (( ${#files[@]} > 0 )) || { fail "$base" "build produced no package"; return 1; }
  publish "${files[@]}" || { fail "$base" "repo-add failed"; return 1; }
  state_set "$base" "$key" "$build" "${pkgnames[*]}"
  rm -rf "$out"
  built+=("$base")
  log "$base: published ${pkgnames[*]}"
}

# -----------------------------------------------------------------------------
# PRUNE
prune() {
  local base name file stale=()
  declare -A keep=() in_closure=() referenced=()
  (( resolve_complete )) || { log "prune skipped, resolution incomplete"; return 0; }
  for base in "${bases[@]}"; do
    in_closure[$base]=1
    for name in $(state_get "$base" names); do keep[$name]=1; done
  done
  for name in "${!db_file[@]}"; do
    [ -n "${keep[$name]:-}" ] || stale+=("$name")
  done
  if (( ${#stale[@]} > 0 )); then
    log "removing ${stale[*]}"
    repo-remove -q "$CACHE/db/$REPO.db.tar.gz" "${stale[@]}" && db_publish
  fi
  for file in "$STATE_DIR"/*; do
    [ -n "${in_closure[$(basename "$file")]:-}" ] || rm -f "$file"
  done
  # superseded and removed files, only now that no published db references them
  for name in "${!db_file[@]}"; do referenced[${db_file[$name]}]=1; done
  for file in "$REPO_DIR"/*.pkg.tar.zst; do
    [ -n "${referenced[$(basename "$file")]:-}" ] || rm -f "$file" "$file.sig"
  done
}

# -----------------------------------------------------------------------------
# STATUS
write_status() {
  local base failures=() now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for base in "${bases[@]}" "${!failed[@]}"; do
    [ -n "${failed[$base]:-}" ] && failures+=("$base: ${failed[$base]}")
  done
  mapfile -t failures < <(printf '%s\n' "${failures[@]}" | sort -u | sed '/^$/d')
  {
    echo "last build: $now"
    echo "source:     $SOURCE $REF $COMMIT"
    echo "packages:   ${#db_file[@]}"
    echo "built:      ${built[*]:-none}"
    echo "failed:     ${#failures[@]}"
    (( ${#failures[@]} == 0 )) || printf '  %s\n' "${failures[@]}"
  } > "$CACHE/status.txt"
  jq -n --arg last_build "$now" --arg commit "$COMMIT" --argjson packages "${#db_file[@]}" \
    --args '{ packages: $packages, failing: ($ARGS.positional | length), last_build: $last_build, commit: $commit, failed: $ARGS.positional }' \
    "${failures[@]}" > "$CACHE/status.json"
  put "$CACHE/status.json" /repo
  put "$CACHE/status.txt" /repo
  cp "$CACHE/status.txt" "$PUBLIC/status.txt"
  cat "$CACHE/status.txt"
}

clean_caches() {
  find "$CACHE/pacman" "$CACHE/src" -maxdepth 2 -type f -mtime +"$CACHE_KEEP_DAYS" -delete
}

# mirror the served tree to the always-on dmz host; never fatal, the nas copy stands regardless
push() {
  [ -n "$PUSH_TARGET" ] && [ -f "$PUSH_KEY_FILE" ] || return 0
  [ -f "$REPO_DIR/$REPO.db" ] || return 0
  log "pushing the repo to $PUSH_TARGET"
  rsync -a --delete --exclude '.state/' \
    -e "ssh -i $PUSH_KEY_FILE -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15" \
    /repo/ "$PUSH_TARGET/" || log "push to $PUSH_TARGET failed, the dmz mirror keeps its last copy"
}

# -----------------------------------------------------------------------------
# MAIN
main() {
  local base
  log "setting up"
  setup_builder
  setup_key
  db_stage
  setup_pacman
  fetch_dotfiles
  log "resolving $DOTFILES/mirror/packages.conf at $COMMIT"
  load_repo_index
  read_conf
  resolve
  plan
  log "${#order[@]} bases"
  for base in "${order[@]}"; do
    [ -n "${failed[$base]:-}" ] || build_base "$base" || true
  done
  prune
  write_status
  push
  clean_caches
}

main "$@"
