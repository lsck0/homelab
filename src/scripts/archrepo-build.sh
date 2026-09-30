#!/usr/bin/env bash
# snapshot every package arch-dotfiles' install.sh installs into the signed lsck0 pacman repo
#
# Runs as root in a fresh archlinux:base-devel container on vm-119 (archbuild.service):
#   /repo              served tree on the nas: x86_64/ (packages, db), status.txt, status.json, .state/
#   /cache             persistent build state on the vm disk: pacman cache, sources, cargo and go caches
#   /public            the builder's status page: build.log, logs/<base>.log, status.txt
#   /run/signing.asc   armored secret signing key
#
# The list is install.sh itself: PACKAGES, CARGO_PKGS and GO_PKGS across every group. PACKAGES
# entries in core, extra or multilib are copied, everything else is built: mirror/pkgbuilds/<name>
# recipes, aur packages with their aur dependencies, crates and go modules. The official closure of
# the whole set is copied at the versions the builds ran against, and clients list [lsck0] above
# [core], so a machine only ever sees a set that resolved together here. Packages keep their names.
#
# Built packages are repacked to turn pkgrel 1 into 1.<n>, n counting the builds of that base, so a
# rebuild never reuses a file name a client may have cached with other contents.
#
# A base is rebuilt when its recipe hash changes (aur commit, crate or module version, local
# PKGBUILD, a -git source's upstream head via pkgver()), its last build is FULL_REBUILD_DAYS old, or
# its packages no longer resolve against today's repos (soname bumps). Everything lands in a staging
# db first; the served db is replaced once, and only when the staged set resolves from [lsck0]
# alone, otherwise the night is held back and clients keep yesterday's set. Old files are deleted
# only after the db that replaced them is published. Crash-only: all state is per base, a killed run
# is picked up by the next one.
set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# CONSTANTS
REPO=lsck0
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
REPACK_VERSION=3
# the arch-dotfiles files the list and the local recipes come from
INSTALL_SCRIPT=install.sh
PKGBUILDS=mirror/pkgbuilds
# dependencies aur recipes forget: <pkgbase> <depends|makedepends> <package>...
OVERRIDES=mirror/overrides.conf
# the 2026 naming served lsck0-<name>; replaces lets a pacman -Syu swap the installed ones over
OLD_PREFIX=lsck0-
AUR_URL=https://aur.archlinux.org
USER_AGENT="lsck0-archbuild (https://github.com/lsck0/arch-dotfiles)"

# -----------------------------------------------------------------------------
# STATE
declare -A kind=() argument=() listed=() names=() deps=() provider=() failed=() repo_has=() db_file=() looked_up=()
bases=()
order=()
aur_wanted=()
official_wanted=()
official_names=()
built=()
# empty while the staged set is publishable, else why the night is held back
held_back=
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
# db_file from the staging db, or from the db given
load_db_index() {
  local name file
  db_file=()
  while read -r name file; do
    db_file[$name]=$file
  done < <(bsdtar -xOf "${1:-$CACHE/db/$REPO.db.tar.gz}" 2>/dev/null \
    | awk '/^%FILENAME%$/ { getline f } /^%NAME%$/ { getline n; print n, f }')
}

# the builder's pacman reads the staging db, so later builds and the resolve checks see what is staged
db_sync_local() {
  cp "$CACHE/db/$REPO.db.tar.gz" "/var/lib/pacman/sync/$REPO.db"
  # the served db's signature would not match the staging copy
  rm -f "/var/lib/pacman/sync/$REPO.db.sig"
  load_db_index
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

# the served db is the truth, the staging copy is rebuilt from it every run; a first run serves an empty one
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
  [ -f "$REPO_DIR/$REPO.db" ] || db_publish
  load_db_index
}

# rel 1 -> 1.<build>; prints the signed package path
repack() {
  local package=$1 build=$2 dir=$CACHE/repack name version arch release file
  rm -rf "$dir"
  mkdir -p "$dir" "$CACHE/stage"
  bsdtar -xpf "$package" -C "$dir" || return 1
  name=$(sed -n 's/^pkgname = //p' "$dir/.PKGINFO")
  version=$(sed -n 's/^pkgver = //p' "$dir/.PKGINFO")
  arch=$(sed -n 's/^arch = //p' "$dir/.PKGINFO")
  [ -n "$name" ] && [ -n "$version" ] && [ -n "$arch" ] || return 1
  release=${version##*-}
  version=${version%-*}
  sed -i -e "s/^pkgver = .*/pkgver = $version-${release%%.*}.$build/" "$dir/.PKGINFO" "$dir/.BUILDINFO"
  printf 'replaces = %s%s\n' "$OLD_PREFIX" "$name" >> "$dir/.PKGINFO"
  file=$CACHE/stage/$name-$version-${release%%.*}.$build-$arch.pkg.tar.zst
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

# files go to the served tree, unreferenced until the staging db is published
stage_add() {
  local file served=()
  for file; do
    put "$file" "$REPO_DIR"
    put "$file.sig" "$REPO_DIR"
    served+=("$REPO_DIR/$(basename "$file")")
  done
  repo-add -q "$CACHE/db/$REPO.db.tar.gz" "${served[@]}" || return 1
  db_sync_local
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
  # the image strips docs and locales, a build dependency must install whole
  sed -i -e '/^NoExtract/d' -e "s|^#\?CacheDir.*|CacheDir = $CACHE/pacman/|" /etc/pacman.conf
  cat >> /etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist

# after the official repos: the staged copies of official packages must not shadow today's versions
[$REPO]
SigLevel = PackageRequired DatabaseOptional
Server = file://$REPO_DIR
EOF
  # the only sync of the run: builds and the snapshot resolve against one state of the official repos
  pacman -Syu --noconfirm --needed git jq expac rsync openssh >/dev/null
  db_sync_local
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

# names, provides and groups of every official package
load_repo_index() {
  local repo name provides group
  while read -r repo name provides; do
    [ "$repo" = "$REPO" ] && continue
    repo_has[$name]=1
    for provides in $provides; do
      repo_has[${provides%%=*}]=1
    done
  done < <(expac -S -l ' ' '%r %n %S %G')
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
  [ -f "$DOTFILES/$PKGBUILDS/$name/PKGBUILD" ] || return 1
  cp -r "$DOTFILES/$PKGBUILDS/$name/." "$dir/"
}

# appends the overrides of one base to its PKGBUILD; succeeds only when it changed something
recipe_override() {
  local base=$1 dir=$2 name field packages changed=1
  [ -f "$DOTFILES/$OVERRIDES" ] || return 1
  while read -r name field packages; do
    [ "$name" = "$base" ] || continue
    case $field in
      depends | makedepends)
        printf '\n%s+=(%s)\n' "$field" "$packages" >> "$dir/PKGBUILD"
        changed=0
        ;;
      *) fail "$base" "unknown override field '$field'"; return 1 ;;
    esac
  done < <(sed 's/#.*//' "$DOTFILES/$OVERRIDES")
  return $changed
}

# recipe dir with a PKGBUILD and its .SRCINFO; records names, provides and deps
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
  # an aur .SRCINFO is shipped, and only stale once an override touched the PKGBUILD
  if [ "${kind[$base]}" != aur ] || recipe_override "$base" "$dir"; then
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
# the entries of one install.sh array, one per line with an optional trailing comment
list_entries() {
  awk -v array="$2" '$0 ~ "^" array "=\\(" { inside = 1; next } inside && /^\)/ { exit }
    inside { sub(/#.*/, ""); if ($1 != "") print $1 }' "$1"
}

read_lists() {
  local script=$DOTFILES/$INSTALL_SCRIPT name spec
  [ -f "$script" ] || { log "no $script"; exit 1; }
  while read -r name; do
    listed[$name]=1
    if [ -f "$DOTFILES/$PKGBUILDS/$name/PKGBUILD" ]; then
      add_base "$name" local
    elif [ -n "${repo_has[$name]:-}" ]; then
      official_wanted+=("$name")
    else
      aur_wanted+=("$name")
    fi
  done < <(list_entries "$script" PACKAGES)
  while read -r name; do
    listed[$name]=1
    add_base "$name" cargo
  done < <(list_entries "$script" CARGO_PKGS)
  while read -r spec; do
    name=${spec%@*}
    name=${name##*/}
    listed[$name]=1
    add_base "$name" go "$spec"
  done < <(list_entries "$script" GO_PKGS)
  (( ${#official_wanted[@]} + ${#aur_wanted[@]} + ${#bases[@]} > 0 )) || { log "no packages in $script"; exit 1; }
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
  local base=$1 key=$2 name built_at names
  [ "$key" = "$(state_get "$base" key)" ] || return 1
  built_at=$(state_get "$base" built)
  (( $(date +%s) - ${built_at:-0} < FULL_REBUILD_DAYS * 86400 )) || return 1
  names=$(state_get "$base" names)
  for name in $names; do
    [ -n "${db_file[$name]:-}" ] || return 1
  done
  # a soname bump in today's repos leaves the old build uninstallable
  pacman -Sp --noconfirm $names >/dev/null 2>&1
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
    pkgnames+=("$(bsdtar -xOf "$package" .PKGINFO | sed -n 's/^pkgname = //p')")
  done
  (( ${#files[@]} > 0 )) || { fail "$base" "build produced no package"; return 1; }
  stage_add "${files[@]}" || { fail "$base" "repo-add failed"; return 1; }
  state_set "$base" "$key" "$build" "${pkgnames[*]}"
  rm -rf "$out"
  built+=("$base")
  log "$base: staged ${pkgnames[*]}"
}

# -----------------------------------------------------------------------------
# SNAPSHOT
# names the staged set is checked and installed by: listed official ones plus everything built
snapshot_targets() {
  local base name
  printf '%s\n' "${official_wanted[@]}"
  for base in "${bases[@]}"; do
    state_get "$base" names | tr ' ' '\n'
  done | while read -r name; do
    [ -n "$name" ] && [ -n "${db_file[$name]:-}" ] && echo "$name"
  done
}

# the official closure of the whole set at today's versions, downloaded into the served tree and staged
snapshot_official() {
  local root=$CACHE/resolve targets=() repo name file new=()
  mapfile -t targets < <(snapshot_targets | sort -u)
  # an empty local db, so the closure includes what the build container has installed
  rm -rf "$root"
  mkdir -p "$root/sync"
  cp /var/lib/pacman/sync/*.db "$root/sync/"
  if ! pacman --dbpath "$root" -Sp --noconfirm --print-format '%r %n %f' "${targets[@]}" \
    > "$CACHE/closure.txt" 2> "$PUBLIC/logs/snapshot.log"; then
    held_back="the set does not resolve against today's repos, logs/snapshot.log"
    return 1
  fi
  official_names=()
  new=()
  while read -r repo name file; do
    [ "$repo" = "$REPO" ] && continue
    official_names+=("$name")
    [ "${db_file[$name]:-}" = "$file" ] || new+=("$repo/$name")
  done < "$CACHE/closure.txt"
  log "snapshot: ${#official_names[@]} official packages, ${#new[@]} new"
  (( ${#new[@]} > 0 )) || return 0
  # the served tree as cache: files already there are verified, not fetched again
  if ! pacman --dbpath "$root" -Sw --noconfirm --cachedir "$REPO_DIR" "${new[@]}" >> "$PUBLIC/logs/snapshot.log" 2>&1; then
    held_back="downloading the official packages failed, logs/snapshot.log"
    return 1
  fi
  new=()
  while read -r repo name file; do
    [ "$repo" = "$REPO" ] || [ "${db_file[$name]:-}" = "$file" ] && continue
    # pacman takes a file its own cache already holds from there instead of downloading it again
    [ -f "$REPO_DIR/$file" ] || put "$CACHE/pacman/$file" "$REPO_DIR" 2>/dev/null \
      || { held_back="$file is in no cache after the download"; return 1; }
    [ -f "$REPO_DIR/$file.sig" ] || sign "$REPO_DIR/$file" || { held_back="signing $file failed"; return 1; }
    new+=("$REPO_DIR/$file")
  done < "$CACHE/closure.txt"
  repo-add -q "$CACHE/db/$REPO.db.tar.gz" "${new[@]}" || { held_back="repo-add of the official packages failed"; return 1; }
  db_sync_local
}

# what a client with [lsck0] above everything sees: the staged set must resolve from it alone
snapshot_verify() {
  local root=$CACHE/verify targets=()
  mapfile -t targets < <(snapshot_targets | sort -u)
  rm -rf "$root"
  mkdir -p "$root/sync"
  cp "$CACHE/db/$REPO.db.tar.gz" "$root/sync/$REPO.db"
  printf '[options]\nArchitecture = auto\nSigLevel = Never\n\n[%s]\nServer = file://%s\n' "$REPO" "$REPO_DIR" > "$root/pacman.conf"
  pacman --config "$root/pacman.conf" --dbpath "$root" -Sp --noconfirm "${targets[@]}" >/dev/null 2>> "$PUBLIC/logs/snapshot.log" \
    || { held_back="the staged set does not resolve from $REPO alone, logs/snapshot.log"; return 1; }
}

# -----------------------------------------------------------------------------
# PRUNE
# staging only: drops what neither a base in the closure nor the official snapshot still needs
prune_db() {
  local base name file stale=()
  declare -A keep=() in_closure=()
  (( resolve_complete )) || { log "prune skipped, resolution incomplete"; return 0; }
  for base in "${bases[@]}"; do
    in_closure[$base]=1
    for name in $(state_get "$base" names); do keep[$name]=1; done
  done
  for name in "${official_names[@]}"; do keep[$name]=1; done
  for name in "${!db_file[@]}"; do
    [ -n "${keep[$name]:-}" ] || stale+=("$name")
  done
  if (( ${#stale[@]} > 0 )); then
    log "removing ${stale[*]}"
    repo-remove -q "$CACHE/db/$REPO.db.tar.gz" "${stale[@]}" && db_sync_local
  fi
  for file in "$STATE_DIR"/*; do
    [ -n "${in_closure[$(basename "$file")]:-}" ] || rm -f "$file"
  done
}

# superseded, removed and held back files, only once no served db references them
prune_files() {
  local name file
  declare -A referenced=()
  load_db_index "$REPO_DIR/$REPO.db.tar.gz"
  for name in "${!db_file[@]}"; do referenced[${db_file[$name]}]=1; done
  for file in "$REPO_DIR"/*.pkg.tar.zst; do
    [ -n "${referenced[$(basename "$file")]:-}" ] || rm -f "$file" "$file.sig"
  done
}

# -----------------------------------------------------------------------------
# STATUS
# the running build as status.json's running field; status.txt stays the last finished run, since
# archbuild-if-stale judges staleness by its age and a killed run must not look fresh
write_progress() {
  local phase=$1 current=${2:-} done=${3:-0} base failures=() previous=/repo/status.json
  for base in "${!failed[@]}"; do failures+=("$base: ${failed[$base]}"); done
  [ -f "$previous" ] || echo '{}' > "$CACHE/status.json"
  [ -f "$previous" ] && cp "$previous" "$CACHE/status.json"
  jq --arg started "$STARTED" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg commit "$COMMIT" --arg phase "$phase" \
    --arg current "$current" --argjson done "$done" --argjson total "${#order[@]}" --argjson built "${#built[@]}" \
    --args '. + { running: { started: $started, updated: $updated, commit: $commit, phase: $phase,
      current: (if $current == "" then null else $current end), done: $done, total: $total, built: $built,
      failing: ($ARGS.positional | length), failed: $ARGS.positional } }' \
    "${failures[@]}" < "$CACHE/status.json" > "$CACHE/status.json.new" && mv -f "$CACHE/status.json.new" "$CACHE/status.json"
  put "$CACHE/status.json" /repo
  push_status
}

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
    echo "official:   ${#official_names[@]}"
    echo "published:  ${held_back:+no, held back: }${held_back:-yes}"
    echo "built:      ${built[*]:-none}"
    echo "failed:     ${#failures[@]}"
    (( ${#failures[@]} == 0 )) || printf '  %s\n' "${failures[@]}"
  } > "$CACHE/status.txt"
  jq -n --arg last_build "$now" --arg commit "$COMMIT" --argjson packages "${#db_file[@]}" --arg held_back "$held_back" \
    --args '{ packages: $packages, failing: ($ARGS.positional | length), last_build: $last_build, commit: $commit,
      held_back: (if $held_back == "" then null else $held_back end), failed: $ARGS.positional, running: null }' \
    "${failures[@]}" > "$CACHE/status.json"
  put "$CACHE/status.json" /repo
  put "$CACHE/status.txt" /repo
  cp "$CACHE/status.txt" "$PUBLIC/status.txt"
  cat "$CACHE/status.txt"
}

clean_caches() {
  find "$CACHE/pacman" "$CACHE/src" -maxdepth 2 -type f -mtime +"$CACHE_KEEP_DAYS" -delete
}

PUSH_SSH="ssh -i $PUSH_KEY_FILE -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

# mirror the served tree to the always-on dmz host; never fatal, the nas copy stands regardless
push() {
  [ -n "$PUSH_TARGET" ] && [ -f "$PUSH_KEY_FILE" ] || return 0
  [ -f "$REPO_DIR/$REPO.db" ] || return 0
  log "pushing the repo to $PUSH_TARGET"
  rsync -a --delete --exclude '.state/' -e "$PUSH_SSH" /repo/ "$PUSH_TARGET/" \
    || log "push to $PUSH_TARGET failed, the dmz mirror keeps its last copy"
}

# only status.json, so the dmz mirror shows a running build; a failed push waits for the next update
push_status() {
  [ -n "$PUSH_TARGET" ] && [ -f "$PUSH_KEY_FILE" ] || return 0
  rsync -a -e "$PUSH_SSH" /repo/status.json "$PUSH_TARGET/status.json" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# MAIN
main() {
  local base done=0
  log "setting up"
  setup_builder
  setup_key
  db_stage
  setup_pacman
  fetch_dotfiles
  log "resolving $DOTFILES/$INSTALL_SCRIPT at $COMMIT"
  write_progress resolving
  load_repo_index
  read_lists
  resolve
  plan
  log "${#order[@]} bases, ${#official_wanted[@]} official packages listed"
  for base in "${order[@]}"; do
    write_progress building "$base" "$done"
    [ -n "${failed[$base]:-}" ] || build_base "$base" || true
    done=$((done + 1))
  done
  write_progress snapshot "" "$done"
  if snapshot_official; then
    prune_db
    write_progress verifying "" "$done"
    snapshot_verify || true
  fi
  if [ -z "$held_back" ]; then
    write_progress publishing "" "$done"
    db_publish
    prune_files
  else
    log "held back: $held_back"
    load_db_index "$REPO_DIR/$REPO.db.tar.gz"
  fi
  write_status
  push
  clean_caches
}

main "$@"
