#!/usr/bin/env bash
# snapshot every package arch-dotfiles lists into the signed lsck0 pacman repo
#
# usage: archrepo-build.sh build|publish
#
# archbuild.service on vm-119 runs it twice per night, each time in a fresh archlinux:base-devel
# container, after archrepo-fetch.sh has checked out a dotfiles commit signed by the pinned key:
#
#   build    untrusted: runs aur and local recipes. Holds no secret and cannot write the served
#            tree; its result is a proposal in /outbox: unsigned packages, the staged db, the official
#            dbs the builds ran against, per base state and a report.
#   publish  trusted: holds the repo key and the push key, and never runs or installs anything a recipe
#            produced. It signs only proposed packages it can vouch for, builds the served db itself
#            with repo-add and publishes it as a dated snapshot.
#
# A malicious recipe can still ship bad contents under its own package names, which installing it
# grants anyway, but can no longer take the key, sign another base's name, take or replace an
# official package, or write the served tree. The publisher holds the builder to this:
#   - a rebuilt base advances its build number; its files are new, named after their .PKGINFO, and
#     carry only names the base owns already or nobody owns
#   - only a local recipe (signed dotfiles) may take or replace the name of an official package
#   - every served name maps to a file of a base's signed state, to the file it serves already, or to
#     the file arch's dbs name for it, which pacman checks against arch's keyring here
#   - a base that fails these checks keeps its served build; the rest of the night publishes
# The builder can still withhold or roll back: drop names, hold a night back, or point an official
# name at an older arch-signed build of it. All of that shows in the status and none of it forges.
#
# Mounts:
#   /repo        served tree on the nas: <date>/x86_64 dated snapshots, current -> the newest one,
#                x86_64/ the pool of signed files plus the newest db, status.{txt,json}, .state/;
#                read-only for build
#   /dotfiles    the verified arch-dotfiles checkout, read-only
#   /outbox      build writes it, publish reads it read-only
#   /cache       build only: pacman cache, sources, cargo and go caches, the staging db
#   /public      build only: the builder's status page, logs/<base>.log, status.json
#   /run/signing.asc, /run/push-key   publish only
#
# The list is archrepo-list.sh's: the packages.txt of every module plus the EXTRA_PACKAGES of every
# platforms/*.sh. Entries in core, extra or multilib are copied, everything else is built:
# mirror/pkgbuilds/<name> recipes and aur packages with their aur dependencies. The official closure
# of the whole set is copied at the versions the builds ran against, and clients list [lsck0] above
# [core], so a machine only ever sees a set that resolved together here. Packages keep their names.
#
# Built packages are repacked to turn pkgrel 1 into 1.<n>, n counting the builds of that base, so a
# rebuild never reuses a file name a client may have cached with other contents.
#
# A base is rebuilt when its recipe hash changes (aur commit, local PKGBUILD, a -git source's
# upstream head via pkgver()), its last build is FULL_REBUILD_DAYS old, or its packages no longer
# resolve against today's repos (soname bumps). The served db is replaced once, and only when the
# set resolves from [lsck0] alone, otherwise the night is held back and clients keep yesterday's set;
# its signed packages wait in the pool for the next night. Old files leave the pool only after the db
# that replaced them is published, and live on as hardlinks in every dated snapshot that names them.
# Crash-only: all state is per base, a killed run is picked up by the next one.
#
# Completeness: arch-dotfiles' install.sh no longer builds what the mirror lacks, so every listed name must
# stay installable from the served snapshot. A failed base keeps its last build staged while that still
# resolves; a night whose db would still lose a listed name the served db provides is held back, so a
# client never misses a package once served. A listed name the served db never provided (never built, not
# in the aur) does not hold the night back, which would stall every other update for it: the night
# publishes without it and it shows at once in status.{txt,json} `missing` and in vm-119's
# homelab_archrepo_missing_packages. Rejected: publishing with the lost name's served build carried over,
# since no closure was resolved for it and drop_unresolvable drops exactly the builds that no longer resolve.
set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# CONSTANTS
REPO=lsck0
ARCH=x86_64
SERVED=/repo
REPO_DIR=$SERVED/$ARCH
SERVED_STATE_DIR=$SERVED/.state
SNAPSHOT_CURRENT=$SERVED/current
SNAPSHOT_MANIFEST=manifest.json
SNAPSHOT_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
# Dated snapshots stay this many days, so a dotfiles generation can pin <date>/x86_64. A snapshot
# hardlinks the pool, so a kept day costs only the files no other kept snapshot has. Measured on the
# served db of 2026-10-05: 30.2 GiB in 3307 files, 7.6 GiB of them built (each base rebuilt at least
# every FULL_REBUILD_DAYS, ~0.55 GiB/day) and ~0.46 GiB/day of official updates (build dates of the
# last 7 days), so ~1 GiB of new files per kept day, on the nas (1.1 TiB free) and on vm-210 (63 GiB
# disk, 33 GiB used); a full rebuild adds 7.6 GiB in one night. 7 days keep vm-210 near 40 GiB and
# under 50 GiB after a full rebuild; each further day needs ~1 GiB more of its disk (210-external-mirror/instance.nix).
SNAPSHOT_KEEP_DAYS=7
CACHE=/cache
# the staging db, rebuilt from the served one every run
STAGE_DB=$CACHE/db/$REPO.db.tar.gz
DB_FILES=("$REPO.db.tar.gz" "$REPO.files.tar.gz")
PUBLIC=/public
DOTFILES=/dotfiles
OUTBOX=/outbox
OUTBOX_POOL=$OUTBOX/pool
OUTBOX_SYNC=$OUTBOX/sync
OUTBOX_STATE=$OUTBOX/state
OUTBOX_DB=$OUTBOX/$REPO.db.tar.gz
OUTBOX_REPORT=$OUTBOX/report.json
# written last by build: publish takes only the outbox of its own run
OUTBOX_RUN=$OUTBOX/run
# publish's scratch space, inside its container
WORK=/var/tmp/archbuild
SIGNING_KEY_FILE=/run/signing.asc
# ssh push to the always-on dmz mirror after each run; empty disables it
PUSH_TARGET=${ARCHBUILD_PUSH_TARGET:-}
PUSH_KEY_FILE=/run/push-key
PUSH_CONNECT_TIMEOUT_S=15
PUSH_SSH="ssh -i $PUSH_KEY_FILE -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=$PUSH_CONNECT_TIMEOUT_S"
# where the commit came from, for the status only; archrepo-fetch.sh verified COMMIT
SOURCE=${ARCHBUILD_SOURCE:-}
REF=${ARCHBUILD_REF:-}
COMMIT=${ARCHBUILD_COMMIT:?the verified arch-dotfiles commit}
# epoch seconds the unit started at: the run id, the snapshot date and the age archbuild-if-stale reads
RUN_STARTED=${ARCHBUILD_RUN_STARTED:?epoch seconds of the run start}
OFFICIAL_REPOS=(core extra multilib)
BUILDER=builder
# the uid every writing container on the nas uses
BUILDER_UID=1000
# soname bumps on a rolling distro break old builds without a version change
FULL_REBUILD_DAYS=14
SECONDS_PER_DAY=86400
# per recipe, so one hung build cannot eat the night
BUILD_TIMEOUT=3h
FETCH_TIMEOUT=15m
BUILD_KILL_AFTER=5m
FETCH_KILL_AFTER=1m
HTTP_TIMEOUT_S=60
HTTP_RETRIES=3
# where a recipe's validpgpkeys come from; makepkg's source check fails a build whose key is missing
KEYSERVER=hkps://keyserver.ubuntu.com
KEY_FETCH_TIMEOUT=2m
# bound on the depth of aur dependency chains
RESOLVE_ROUNDS_MAX=16
# names per aur rpc request
RPC_BATCH=100
CACHE_KEEP_DAYS=30
# idle days before a go build cache entry goes: it only speeds up the next build of the same package, an expired
# one costs one cold compile, and kept forever the cache grows without bound on the 98 GiB disk
BUILD_CACHE_KEEP_DAYS=14
# part of every rebuild key: bump it when repack changes what a published package contains
REPACK_VERSION=3
# prints the package list of a dotfiles checkout (archrepo-list.sh, mounted next to this script)
LIST_SCRIPT=/list.sh
# the arch-dotfiles files the local recipes and the packager name come from
PKGBUILDS=mirror/pkgbuilds
# dependencies aur recipes forget: <pkgbase> <depends|makedepends> <package>...
OVERRIDES=mirror/overrides.conf
# the public half of the repo key, which clients trust
REPO_PUBLIC_KEY=configs/base/pacman/archrepo.asc
# the 2026 naming served lsck0-<name>; replaces lets a pacman -Syu swap the installed ones over
OLD_PREFIX=lsck0-
AUR_URL=https://aur.archlinux.org
USER_AGENT="lsck0-archbuild (https://github.com/lsck0/arch-dotfiles)"
# makepkg's pkgname rule: alphanumerics and @._+-, not starting with a hyphen or a dot
NAME_PATTERN='^[a-z0-9@_+][a-z0-9@._+-]*$'
# <name>-<epoch:version>-<release>-<arch>.pkg.tar.zst, nothing a path could hide in
FILE_PATTERN='^[a-z0-9@_+][a-z0-9@._+-]*-[A-Za-z0-9.:_+~]+-[0-9.]+-(x86_64|any)\.pkg\.tar\.zst$'
# a recipe key is a sha256
KEY_PATTERN='^[0-9a-f]{64}$'
# bytes of the held back reason that quotes rejected names
HELD_BACK_QUOTE_MAX=300
TIME_FORMAT=+%Y-%m-%dT%H:%M:%SZ
DATE_FORMAT=+%Y-%m-%d

# -----------------------------------------------------------------------------
# STATE
declare -A kind=() listed=() names=() deps=() provider=() failed=() repo_has=() db_file=() looked_up=()
bases=()
order=()
aur_wanted=()
official_wanted=()
official_names=()
built=()
# failed bases whose old build no longer resolves, removed from the staged set
dropped=()
# empty while the staged set is publishable, else why the night is held back
held_back=
STARTED=$(date -u -d "@$RUN_STARTED" "$TIME_FORMAT")
SNAPSHOT=$(date -u -d "@$RUN_STARTED" "$DATE_FORMAT")
# prune only when every base is known, a transient fetch error must not delete packages
resolve_complete=1
# build: the working copy of the served state; publish: the served state
STATE_DIR=
KEY=
BASELINE_PACKAGES=
# publish: the served db (name -> file), the signed state (file -> name, name -> base), arch's names
# today, and the db it serves next (name -> file)
declare -A served=() state_file=() owner_of=() official_name=() final=()
# publish: the listed names the served db lacks, then the proposed one, one per line
snapshot_missing=
proposed_missing=
push_failed=0

# -----------------------------------------------------------------------------
# HELPERS
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

fail() {
  failed[$1]=$2
  log "FAIL $1: $2"
}

http() { curl -fsSL --max-time "$HTTP_TIMEOUT_S" --retry "$HTTP_RETRIES" -A "$USER_AGENT" "$@"; }

# a command prefix, not a function: timeout runs it
AS_BUILDER=(sudo -u "$BUILDER" -H env CARGO_HOME="$CACHE/cargo"
  GOPATH="$CACHE/go" GOMODCACHE="$CACHE/go/mod" GOCACHE="$CACHE/go/build")

# .SRCINFO values of one key, arch-specific ones included
srcinfo_get() {
  awk -v k="$2" '{ sub(/^[ \t]+/, "") } ($1 == k || $1 == k "_x86_64") && $2 == "=" { print $3 }' "$1"
}

# a base without a state file has no value yet
state_get_from() { [ ! -f "$1/$2" ] || sed -n "s/^$3=//p" "$1/$2"; }

state_get() { state_get_from "$STATE_DIR" "$1" "$2"; }

state_set() {
  local base=$1 key=$2 build=$3 pkgnames=$4 files=$5
  printf 'key=%s\nbuild=%s\nbuilt=%s\nnames=%s\nfiles=%s\n' "$key" "$build" "$(date +%s)" "$pkgnames" "$files" \
    > "$STATE_DIR/.$base.tmp" || return 1
  mv -f "$STATE_DIR/.$base.tmp" "$STATE_DIR/$base"
}

# copy then rename, a reader never sees half a file
put() {
  local name=${3:-$(basename "$1")}
  cp "$1" "$2/.$name.tmp" || return 1
  mv -f "$2/.$name.tmp" "$2/$name"
}

# hardlink then rename: the same file under a second name, swapped in whole
link_into() {
  local name=${3:-$(basename "$1")}
  ln -f "$1" "$2/.$name.tmp" || return 1
  mv -f "$2/.$name.tmp" "$2/$name"
}

# symlink then rename, so the old link is never missing for a moment
symlink_set() {
  local tmp
  tmp="$(dirname "$2")/.$(basename "$2").tmp"
  ln -sfn "$1" "$tmp" || return 1
  mv -fT "$tmp" "$2"
}

# a detached signature next to the file, renamed into place only once it verifies
sign() {
  local tmp
  tmp="$(dirname "$1")/.$(basename "$1").sig.tmp"
  gpg --batch --yes --detach-sign --no-armor -u "$KEY" -o "$tmp" "$1" || return 1
  gpg --batch --verify "$tmp" "$1" 2>/dev/null || return 1
  mv -f "$tmp" "$1.sig"
}

# against today's official repos and the staging db
names_resolve() { pacman -Sp --noconfirm "$@" >/dev/null 2>&1; }

# one field of the .PKGINFO on stdin
pkginfo_get() { sed -n "s/^$1 = //p"; }

# one "<base>: <reason>" line per failed base
failures_list() {
  local base
  for base in "${!failed[@]}"; do echo "$base: ${failed[$base]}"; done
}

json_array() { jq -n '$ARGS.positional' --args "$@"; }

# listed names <db> provides neither as a name, a provides nor a group; without a db, every listed name
listed_missing() {
  if [ -f "$1" ]; then bash "$LIST_SCRIPT" "$DOTFILES" "$1"; else bash "$LIST_SCRIPT" "$DOTFILES"; fi
}

# the package name of a <name>-<version>-<release>-<arch>.pkg.tar.zst file name
file_package_name() { printf '%s' "${1%-*-*-*}"; }

# a regular file in the outbox, never a link into something the reader's mounts hold
outbox_file_check() { [ -f "$1" ] && [ ! -L "$1" ]; }

# -----------------------------------------------------------------------------
# REPO
# db_file from the staging db, or from the db given; a db that cannot be read stops the caller, an
# empty index would look like a repo without packages
load_db_index() {
  local db=${1:-$STAGE_DB} index name file
  index=$(bsdtar -xOf "$db" | awk '/^%FILENAME%$/ { getline f } /^%NAME%$/ { getline n; print n, f }') \
    || { log "cannot read $db"; return 1; }
  db_file=()
  while read -r name file; do
    [ -z "$name" ] || db_file[$name]=$file
  done <<<"$index"
}

# the served db pair copied into <dir>, an empty pair on a first run
db_copy_served() {
  local dir=$1 f
  mkdir -p "$dir"
  for f in "${DB_FILES[@]}"; do
    if [ -f "$REPO_DIR/$f" ]; then cp "$REPO_DIR/$f" "$dir/$f"; else bsdtar -czf "$dir/$f" --files-from /dev/null; fi
  done
}

# a fresh pacman dbpath with an empty local db and a sync/ to fill
dbpath_create() {
  rm -rf "$1"
  mkdir -p "$1/sync"
}

# arch's keyring and the official repos, multilib included
pacman_setup_official() {
  pacman-key --init >/dev/null
  pacman-key --populate archlinux >/dev/null
  printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
}

# -----------------------------------------------------------------------------
# BUILD: SETUP
# the builder's pacman reads the staging db, so later builds and the resolve checks see what is staged
db_sync_local() {
  cp "$STAGE_DB" "/var/lib/pacman/sync/$REPO.db" || return 1
  load_db_index
}

# the served db is the truth, the staging copy is rebuilt from it every run; a first run starts empty
db_stage() {
  db_copy_served "$CACHE/db"
  load_db_index
}

setup_build() {
  local packager
  id "$BUILDER" >/dev/null 2>&1 || useradd -m -u "$BUILDER_UID" "$BUILDER"
  # regenerated every run; a stale recipe would linger as a base that is no longer wanted
  rm -rf "$CACHE/build" "$CACHE/out" "$CACHE/recipes"
  mkdir -p "$CACHE"/{pacman,src,build,aur,recipes,out,stage,cargo,go} "$PUBLIC/logs"
  chown "$BUILDER:" "$CACHE"/{src,build,recipes,out,cargo,go}
  # a killed run's proposal must never be read as this run's
  find "$OUTBOX" -mindepth 1 -delete
  mkdir -p "$OUTBOX_POOL" "$OUTBOX_SYNC"
  STATE_DIR=$CACHE/state
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  [ ! -d "$SERVED_STATE_DIR" ] || cp -a "$SERVED_STATE_DIR/." "$STATE_DIR/"
  packager=$(gpg --show-keys --with-colons "$DOTFILES/$REPO_PUBLIC_KEY" | awk -F: '$1 == "uid" { print $10; exit }')
  [ -n "$packager" ] || { log "no key uid in $DOTFILES/$REPO_PUBLIC_KEY"; exit 1; }
  cat > /etc/makepkg.conf.d/archbuild.conf <<EOF
MAKEFLAGS="-j$(nproc)"
BUILDDIR=$CACHE/build
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
PACKAGER="$packager"
EOF
}

setup_build_pacman() {
  pacman_setup_official
  # the image strips docs and locales, a build dependency must install whole
  sed -i -e '/^NoExtract/d' -e "s|^#\?CacheDir.*|CacheDir = $CACHE/pacman/|" /etc/pacman.conf
  # the only sync of the run: builds and the snapshot resolve against one state of the official repos
  pacman -Syu --noconfirm --needed git jq expac >/dev/null
  # added after the sync, which would look for a served db: db_sync_local installs the staging one.
  # After the official repos, so the staged copies of official packages never shadow today's versions;
  # SigLevel Never, since the staged packages are this container's own unsigned builds, publish checks them
  cat >> /etc/pacman.conf <<EOF

[$REPO]
SigLevel = Never
Server = file://$OUTBOX_POOL
Server = file://$REPO_DIR
EOF
  db_sync_local
  git config --global --add safe.directory '*'
  BASELINE_PACKAGES=$(pacman -Qq)
}

# names, provides and groups of every official package
load_repo_index() {
  local repo name provides
  # provides takes the rest of the line: the provides and the groups
  while read -r repo name provides; do
    [ "$repo" = "$REPO" ] && continue
    repo_has[$name]=1
    for provides in $provides; do
      repo_has[${provides%%=*}]=1
    done
  done < <(expac -S -l ' ' '%r %n %S %G')
}

# -----------------------------------------------------------------------------
# BUILD: RECIPES
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
  [[ $base =~ $NAME_PATTERN ]] || { fail "$base" "not a package base name"; return 1; }
  rm -rf "$dir"
  mkdir -p "$dir"
  case ${kind[$base]} in
    aur) recipe_aur "$base" "$dir" ;;
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
  bases+=("$1")
  materialize "$1" || true
}

# -----------------------------------------------------------------------------
# BUILD: RESOLVE
read_lists() {
  local list name
  list=$(bash "$LIST_SCRIPT" "$DOTFILES") || { log "reading the package list of $DOTFILES failed"; exit 1; }
  while read -r name; do
    listed[$name]=1
    if [ -f "$DOTFILES/$PKGBUILDS/$name/PKGBUILD" ]; then
      add_base "$name" local
    elif [ -n "${repo_has[$name]:-}" ]; then
      official_wanted+=("$name")
    else
      aur_wanted+=("$name")
    fi
  done <<<"$list"
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
      if [ -z "$base" ] && [ -z "${listed[$name]:-}" ]; then
        base=$(aur_base_providing "$name") || { log "aur search for $name failed"; resolve_complete=0; continue; }
      fi
      # the rpc answered, so a listed name missing from it is gone for good and must not block pruning
      if [ -z "$base" ]; then
        [ -z "${listed[$name]:-}" ] || fail "$name" "not in the aur"
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
# BUILD: BUILD
is_vcs() { grep -Eq '^\s*source(_x86_64)? = ([^ ]*::)?(git|hg|svn|bzr|fossil)\+' "$1/.SRCINFO"; }

recipe_key() {
  { echo "repack $REPACK_VERSION"; cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } \
    | sha256sum | cut -d' ' -f1
}

is_current() {
  local base=$1 key=$2 name built_at names=() files
  [ "$key" = "$(state_get "$base" key)" ] || return 1
  built_at=$(state_get "$base" built)
  (( $(date +%s) - ${built_at:-0} < FULL_REBUILD_DAYS * SECONDS_PER_DAY )) || return 1
  read -ra names <<<"$(state_get "$base" names)"
  files=" $(state_get "$base" files) "
  # the staged file must be this build's, a held back or killed run leaves the previous one served
  for name in "${names[@]}"; do
    [ -n "${db_file[$name]:-}" ] && [[ $files == *" ${db_file[$name]} "* ]] || return 1
  done
  # a soname bump in today's repos leaves the old build uninstallable
  names_resolve "${names[@]}"
}

# what makepkg -s would install, installed by root: the build user gets no pacman of its own
build_deps_install() {
  local dir=$1 wanted=() missing=()
  mapfile -t wanted < <({ srcinfo_get "$dir/.SRCINFO" depends; srcinfo_get "$dir/.SRCINFO" makedepends; } | sort -u)
  (( ${#wanted[@]} > 0 )) || return 0
  # -T prints the unsatisfied ones and exits 127 when there are any
  mapfile -t missing < <(pacman -T "${wanted[@]}")
  (( ${#missing[@]} > 0 )) || return 0
  pacman -S --noconfirm --needed --asdeps "${missing[@]}"
}

remove_build_deps() {
  local extra=()
  mapfile -t extra < <(comm -13 <(sort <<<"$BASELINE_PACKAGES") <(pacman -Qq | sort))
  (( ${#extra[@]} == 0 )) || pacman -Rdd --noconfirm "${extra[@]}" >/dev/null \
    || log "removing the build dependencies failed, later builds see them"
}

# rel 1 -> 1.<build>; prints the unsigned package path
repack() {
  local package=$1 build=$2 dir=$CACHE/repack name version arch release file old new
  rm -rf "$dir"
  mkdir -p "$dir" "$CACHE/stage" || return 1
  bsdtar -xpf "$package" -C "$dir" || return 1
  name=$(pkginfo_get pkgname < "$dir/.PKGINFO")
  version=$(pkginfo_get pkgver < "$dir/.PKGINFO")
  arch=$(pkginfo_get arch < "$dir/.PKGINFO")
  [ -n "$name" ] && [ -n "$version" ] && [ -n "$arch" ] || return 1
  release=${version##*-}
  version=${version%-*}
  old=$(printf '%s' "$version-$release" | sed 's/[][\.*^$/+?(){}|]/\\&/g')
  new=$version-${release%%.*}.$build
  sed -i -e "s/^pkgver = .*/pkgver = $new/" "$dir/.PKGINFO" "$dir/.BUILDINFO" || return 1
  # a pin on a sibling of this base (python-frida needs frida=17.18.0-2) must follow the new release
  sed -i -E "s/^((depend|optdepend|provides|conflicts) = [^=<>]+[=<>]+)$old(:|$)/\1$new\3/" "$dir/.PKGINFO" || return 1
  printf 'replaces = %s%s\n' "$OLD_PREFIX" "$name" >> "$dir/.PKGINFO" || return 1
  file=$CACHE/stage/$name-$version-${release%%.*}.$build-$arch.pkg.tar.zst
  # same file list, order and mtree options as makepkg's create_package; the mtree is written outside the tree it lists
  (
    cd "$dir"
    shopt -s dotglob globstar
    export LC_COLLATE=C
    printf '%s\0' **/* | bsdtar -cnf - --format=mtree \
      --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
      --null --files-from - --exclude .MTREE | gzip -c -f -n > "$CACHE/repack.mtree"
    mv -f "$CACHE/repack.mtree" .MTREE
    printf '%s\0' **/* | bsdtar --no-fflags -cnf - --null --files-from - | zstd -c -T0 -q > "$file"
  ) || return 1
  echo "$file"
}

# files go to the outbox; the staging db and this container's pacman see them right away
stage_add() {
  local file staged=()
  for file; do
    put "$file" "$OUTBOX_POOL" || return 1
    staged+=("$OUTBOX_POOL/$(basename "$file")")
  done
  repo-add -q "$STAGE_DB" "${staged[@]}" || return 1
  db_sync_local
}

# a held back or killed night leaves its signed packages in the pool, unpublished; the same recipe stages them again
restage() {
  local base=$1 key=$2 file files=()
  [ "$key" = "$(state_get "$base" key)" ] || return 1
  for file in $(state_get "$base" files); do
    [ -f "$REPO_DIR/$file" ] && [ -f "$REPO_DIR/$file.sig" ] || return 1
    files+=("$REPO_DIR/$file")
  done
  (( ${#files[@]} > 0 )) || return 1
  repo-add -q "$STAGE_DB" "${files[@]}" || return 1
  db_sync_local
}

build_base() {
  local base=$1 dir=$CACHE/recipes/$1 log=$PUBLIC/logs/$1.log out=$CACHE/out/$1 key build package file files=() pkgnames=()
  : > "$log"
  # per base: recipes name different tarballs alike (tree-sitter-json-0.24.8.tar.gz from github and pypi)
  install -d -o "$BUILDER" "$CACHE/src/$base"
  # pkgver() writes upstream's head into the PKGBUILD, which moves the key
  if is_vcs "$dir"; then
    (cd "$dir" && timeout -k "$FETCH_KILL_AFTER" "$FETCH_TIMEOUT" "${AS_BUILDER[@]}" SRCDEST="$CACHE/src/$base" makepkg -od --noprepare --skipinteg --noconfirm) >> "$log" 2>&1 \
      || log "$base: upstream version check failed, building from the recipe as is"
  fi
  key=$(recipe_key "$dir") || { fail "$base" "hashing the recipe failed"; return 1; }
  is_current "$base" "$key" && return 0
  if restage "$base" "$key" && is_current "$base" "$key"; then
    log "$base: staged again from an unpublished run"
    return 0
  fi
  build=$(( $(state_get "$base" build) + 1 ))
  log "$base: building (build $build)"
  srcinfo_get "$dir/.SRCINFO" validpgpkeys | xargs -r timeout "$KEY_FETCH_TIMEOUT" sudo -u "$BUILDER" -H \
    gpg --keyserver "$KEYSERVER" --recv-keys >> "$log" 2>&1 || log "$base: fetching its validpgpkeys failed"
  rm -rf "$out"
  install -d -o "$BUILDER" "$out" || { fail "$base" "creating $out failed"; return 1; }
  if ! build_deps_install "$dir" >> "$log" 2>&1; then
    remove_build_deps
    fail "$base" "installing the build dependencies failed, logs/$base.log"
    return 1
  fi
  if ! (cd "$dir" && timeout -k "$BUILD_KILL_AFTER" "$BUILD_TIMEOUT" "${AS_BUILDER[@]}" SRCDEST="$CACHE/src/$base" PKGDEST="$out" makepkg -fc --noconfirm --nocheck) >> "$log" 2>&1; then
    remove_build_deps
    fail "$base" "build failed, logs/$base.log"
    return 1
  fi
  remove_build_deps
  rm -f "$CACHE"/stage/*
  for package in "$out"/*.pkg.tar.zst; do
    file=$(repack "$package" "$build") || { fail "$base" "repack failed"; return 1; }
    files+=("$file")
    pkgnames+=("$(bsdtar -xOf "$package" .PKGINFO | pkginfo_get pkgname)")
  done
  (( ${#files[@]} > 0 )) || { fail "$base" "build produced no package"; return 1; }
  stage_add "${files[@]}" || { fail "$base" "repo-add failed"; return 1; }
  state_set "$base" "$key" "$build" "${pkgnames[*]}" "$(for file in "${files[@]}"; do basename "$file"; done | xargs)" \
    || { fail "$base" "writing its state failed"; return 1; }
  rm -rf "$out"
  built+=("$base")
  log "$base: staged ${pkgnames[*]}"
}

# -----------------------------------------------------------------------------
# BUILD: SNAPSHOT
# names the staged set is checked and installed by: listed official ones plus everything built
snapshot_targets() {
  local base name
  # an empty array would print one empty line, which pacman takes as a target
  (( ${#official_wanted[@]} == 0 )) || printf '%s\n' "${official_wanted[@]}"
  for base in "${bases[@]}"; do
    state_get "$base" names | tr ' ' '\n'
  done | while read -r name; do
    [ -n "$name" ] && [ -n "${db_file[$name]:-}" ] && echo "$name"
  done
}

# a failed base keeps its last build staged, unless that no longer resolves and would hold back the night
drop_unresolvable() {
  local base name staged
  for base in "${bases[@]}"; do
    [ -n "${failed[$base]:-}" ] || continue
    staged=()
    for name in $(state_get "$base" names); do
      [ -z "${db_file[$name]:-}" ] || staged+=("$name")
    done
    if (( ${#staged[@]} == 0 )) || names_resolve "${staged[@]}"; then continue; fi
    log "$base: dropping ${staged[*]}, the last build no longer resolves"
    repo-remove -q "$STAGE_DB" "${staged[@]}" || continue
    db_sync_local
    dropped+=("$base")
  done
}

# the official closure of the whole set at today's versions, into the outbox and staged
snapshot_official() {
  local root=$CACHE/resolve targets=() repo name file path new=() cachedirs=()
  mapfile -t targets < <(snapshot_targets | sort -u)
  # an empty local db, so the closure includes what the build container has installed
  dbpath_create "$root"
  cp /var/lib/pacman/sync/*.db "$root/sync/" || { held_back="copying the sync dbs failed"; return 1; }
  # publish downloads and checks the official files against the dbs this closure came from
  for repo in "${OFFICIAL_REPOS[@]}"; do
    cp "/var/lib/pacman/sync/$repo.db" "$OUTBOX_SYNC/" || { held_back="copying the $repo db failed"; return 1; }
  done
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
  # downloads land in the outbox; a file the pacman cache or the pool holds already is used in place
  cachedirs=(--cachedir "$OUTBOX_POOL" --cachedir "$CACHE/pacman")
  # a first run has no pool yet, and this container cannot create it
  [ ! -d "$REPO_DIR" ] || cachedirs+=(--cachedir "$REPO_DIR")
  if ! pacman --dbpath "$root" -Swdd --noconfirm "${cachedirs[@]}" "${new[@]}" >> "$PUBLIC/logs/snapshot.log" 2>&1; then
    held_back="downloading the official packages failed, logs/snapshot.log"
    return 1
  fi
  new=()
  while read -r repo name file; do
    [ "$repo" = "$REPO" ] || [ "${db_file[$name]:-}" = "$file" ] && continue
    path=$REPO_DIR/$file
    if [ ! -f "$path" ]; then
      [ -f "$OUTBOX_POOL/$file" ] || put "$CACHE/pacman/$file" "$OUTBOX_POOL" 2>/dev/null \
        || { held_back="$file is in no cache after the download"; return 1; }
      path=$OUTBOX_POOL/$file
    fi
    new+=("$path")
  done < "$CACHE/closure.txt"
  repo-add -q "$STAGE_DB" "${new[@]}" || { held_back="repo-add of the official packages failed"; return 1; }
  db_sync_local
}

# staging only: drops what neither a base in the closure nor the snapshot still needs
prune_db() {
  local base name file repo stale=()
  declare -A keep=() in_closure=()
  (( resolve_complete )) || { log "prune skipped, resolution incomplete"; return 0; }
  for base in "${bases[@]}"; do
    in_closure[$base]=1
    for name in $(state_get "$base" names); do keep[$name]=1; done
  done
  # lsck0 lines too: an official package arch dropped resolves from the staged copy alone
  while read -r repo name file; do keep[$name]=1; done < "$CACHE/closure.txt"
  for name in "${!db_file[@]}"; do
    [ -n "${keep[$name]:-}" ] || stale+=("$name")
  done
  if (( ${#stale[@]} > 0 )); then
    log "removing ${stale[*]}"
    repo-remove -q "$STAGE_DB" "${stale[@]}" && db_sync_local
  fi
  for file in "$STATE_DIR"/*; do
    [ -n "${in_closure[$(basename "$file")]:-}" ] || rm -f "$file"
  done
}

# -----------------------------------------------------------------------------
# BUILD: OUTBOX
# the running build on the builder's status page; the served status.json is publish's
write_progress() {
  local phase=$1 current=${2:-} done=${3:-0} failures=() previous=$SERVED/status.json
  mapfile -t failures < <(failures_list)
  if [ -f "$previous" ]; then cp "$previous" "$CACHE/status.json"; else echo '{}' > "$CACHE/status.json"; fi
  jq --arg started "$STARTED" --arg updated "$(date -u "$TIME_FORMAT")" --arg commit "$COMMIT" --arg phase "$phase" \
    --arg current "$current" --argjson "done" "$done" --argjson total "${#order[@]}" --argjson built "${#built[@]}" \
    --args '. + { running: { started: $started, updated: $updated, commit: $commit, phase: $phase,
      current: (if $current == "" then null else $current end), done: $done, total: $total, built: $built,
      failing: ($ARGS.positional | length), failed: $ARGS.positional } }' \
    "${failures[@]}" < "$CACHE/status.json" > "$CACHE/status.json.new" && mv -f "$CACHE/status.json.new" "$CACHE/status.json"
  put "$CACHE/status.json" "$PUBLIC"
}

# the proposal: staged db, working state and report; the run id last, it marks the outbox complete
outbox_write() {
  local failures=() targets=()
  mapfile -t failures < <(failures_list)
  mapfile -t targets < <(snapshot_targets | sort -u)
  cp "$STAGE_DB" "$OUTBOX_DB"
  cp -a "$STATE_DIR" "$OUTBOX_STATE"
  jq -n --arg held_back "$held_back" --argjson official "${#official_names[@]}" \
    --argjson built "$(json_array "${built[@]}")" \
    --argjson dropped "$(json_array "${dropped[@]}")" \
    --argjson targets "$(json_array "${targets[@]}")" \
    --args '{ held_back: (if $held_back == "" then null else $held_back end), official: $official,
      built: $built, dropped: $dropped, targets: $targets, failed: $ARGS.positional }' \
    "${failures[@]}" > "$OUTBOX_REPORT"
  echo "$RUN_STARTED" > "$OUTBOX_RUN"
}

clean_caches() {
  find "$CACHE/pacman" "$CACHE/src" -maxdepth 2 -type f -mtime +"$CACHE_KEEP_DAYS" -delete
  # go trims its build cache by mtime itself, but only while some go build runs; go/mod and cargo/ are fetched
  # sources, kept so a rebuild does not download them again
  [ ! -d "$CACHE/go/build" ] || find "$CACHE/go/build" -type f -mtime +"$BUILD_CACHE_KEEP_DAYS" -delete
}

# -----------------------------------------------------------------------------
# PUBLISH: SETUP
setup_key() {
  gpg --batch --import "$SIGNING_KEY_FILE" 2>/dev/null
  KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  [ -n "$KEY" ] || { log "no signing key in $SIGNING_KEY_FILE"; exit 1; }
}

# official repos only: nothing the builder produced is ever installed here
setup_publish_pacman() {
  local name
  pacman_setup_official
  pacman -Syu --noconfirm --needed jq rsync openssh >/dev/null
  while read -r name; do official_name[$name]=1; done < <(pacman -Slq "${OFFICIAL_REPOS[@]}")
  (( ${#official_name[@]} > 0 )) || { log "no official package names"; exit 1; }
}

# the outbox of this run, complete, with no link where publish reads
outbox_check() {
  local dir
  for dir in "$OUTBOX" "$OUTBOX_POOL" "$OUTBOX_SYNC" "$OUTBOX_STATE"; do
    if [ ! -d "$dir" ] || [ -L "$dir" ]; then log "$dir is not a directory"; exit 1; fi
  done
  if ! outbox_file_check "$OUTBOX_RUN" || [ "$(cat "$OUTBOX_RUN")" != "$RUN_STARTED" ]; then
    log "the outbox is not from this run ($RUN_STARTED), the build did not finish"
    exit 1
  fi
  if ! outbox_file_check "$OUTBOX_DB" || ! outbox_file_check "$OUTBOX_REPORT"; then log "the outbox has no db or report"; exit 1; fi
}

# served from the served db, state_file and owner_of from the signed state
served_load() {
  local path base name file
  if [ -f "$REPO_DIR/$REPO.db.tar.gz" ]; then
    load_db_index "$REPO_DIR/$REPO.db.tar.gz"
    for name in "${!db_file[@]}"; do served[$name]=${db_file[$name]}; done
  fi
  for path in "$STATE_DIR"/*; do
    base=$(basename "$path")
    for name in $(state_get "$base" names); do owner_of[$name]=$base; done
    for file in $(state_get "$base" files); do state_file[$file]=$(file_package_name "$file"); done
  done
}

# -----------------------------------------------------------------------------
# PUBLISH: ACCEPT
base_reject() { fail "$1" "rejected: $2"; }

# one rebuilt base of the proposal, signed into the pool only when it may publish what it built;
# a rejection keeps its served build, only an unexpected error stops the publish
base_accept() {
  local base=$1 key build previous names files name file path pkginfo package version arch replaced is_local=
  declare -A declared=()
  [[ $base =~ $NAME_PATTERN ]] || { base_reject "$base" "not a package base name"; return 0; }
  outbox_file_check "$OUTBOX_STATE/$base" || { base_reject "$base" "no state in the outbox"; return 0; }
  [ ! -f "$DOTFILES/$PKGBUILDS/$base/PKGBUILD" ] || is_local=1
  key=$(state_get_from "$OUTBOX_STATE" "$base" key)
  build=$(state_get_from "$OUTBOX_STATE" "$base" build)
  names=$(state_get_from "$OUTBOX_STATE" "$base" names)
  files=$(state_get_from "$OUTBOX_STATE" "$base" files)
  previous=$(state_get "$base" build)
  [[ $key =~ $KEY_PATTERN ]] || { base_reject "$base" "recipe key '$key'"; return 0; }
  # a reused build number would reuse a file name a client may have cached with other contents
  if ! [[ $build =~ ^[0-9]+$ ]] || (( build <= ${previous:-0} )); then
    base_reject "$base" "build $build does not follow ${previous:-0}"
    return 0
  fi
  [ -n "$names" ] && [ -n "$files" ] || { base_reject "$base" "no names or files"; return 0; }
  for name in $names; do
    [[ $name =~ $NAME_PATTERN ]] || { base_reject "$base" "package name '$name'"; return 0; }
    [ -z "${owner_of[$name]:-}" ] || [ "${owner_of[$name]}" = "$base" ] || { base_reject "$base" "$name belongs to ${owner_of[$name]}"; return 0; }
    [ -n "$is_local" ] || [ -z "${official_name[$name]:-}" ] || { base_reject "$base" "$name is an official package"; return 0; }
    declared[$name]=0
  done
  rm -rf "$WORK/accept"
  mkdir -p "$WORK/accept"
  for file in $files; do
    [[ $file =~ $FILE_PATTERN ]] || { base_reject "$base" "file name '$file'"; return 0; }
    # a file in the pool that nothing signed references is a killed publish's, never seen by a client
    if [ -e "$REPO_DIR/$file" ] && { [ -n "${state_file[$file]:-}" ] || [ "${served[$(file_package_name "$file")]:-}" = "$file" ]; }; then
      base_reject "$base" "$file exists in the pool already"
      return 0
    fi
    outbox_file_check "$OUTBOX_POOL/$file" || { base_reject "$base" "$file is not in the outbox"; return 0; }
    # checked and signed as a copy of its own: what was checked is what gets signed
    path=$WORK/accept/$file
    cp "$OUTBOX_POOL/$file" "$path"
    pkginfo=$(bsdtar -xOf "$path" .PKGINFO 2>/dev/null) || { base_reject "$base" "$file has no readable .PKGINFO"; return 0; }
    package=$(pkginfo_get pkgname <<<"$pkginfo")
    version=$(pkginfo_get pkgver <<<"$pkginfo")
    arch=$(pkginfo_get arch <<<"$pkginfo")
    [ "$file" = "$package-$version-$arch.pkg.tar.zst" ] || { base_reject "$base" "$file is $package-$version-$arch inside"; return 0; }
    [ "${declared[$package]:-}" = 0 ] || { base_reject "$base" "$file is $package, which is not an open name of $names"; return 0; }
    declared[$package]=1
    # replaces makes a pacman -Syu swap the replaced package out on every machine, listed there or not
    while read -r replaced; do
      replaced=${replaced%%[<>=]*}
      [ -n "$is_local" ] || [ -z "${official_name[$replaced]:-}" ] || { base_reject "$base" "$file replaces the official $replaced"; return 0; }
    done < <(pkginfo_get replaces <<<"$pkginfo")
  done
  for name in $names; do
    [ "${declared[$name]}" = 1 ] || { base_reject "$base" "no file for $name"; return 0; }
  done
  # files first, state last: a killed publish leaves files nothing references, which the next one may overwrite
  for file in $files; do
    sign "$WORK/accept/$file"
    put "$WORK/accept/$file.sig" "$REPO_DIR"
    put "$WORK/accept/$file" "$REPO_DIR"
  done
  state_set "$base" "$key" "$build" "$names" "$files"
  rm -rf "$WORK/accept"
  for name in $names; do owner_of[$name]=$base; done
  for file in $files; do state_file[$file]=$(file_package_name "$file"); done
  built+=("$base")
  log "$base: signed $files"
}

# bases the builder pruned leave the signed state once the published db names none of their files
state_prune() {
  local path base file
  for path in "$STATE_DIR"/*; do
    base=$(basename "$path")
    [ ! -e "$OUTBOX_STATE/$base" ] || continue
    for file in $(state_get "$base" files); do
      [ "${final[$(file_package_name "$file")]:-}" != "$file" ] || continue 2
    done
    rm -f "$path"
  done
}

# -----------------------------------------------------------------------------
# PUBLISH: ASSEMBLE
# final from the proposed names. Each one's file must be a signed build of it or the file served for it
# already; a base's name that is neither keeps its served file; any other name is official and maps to
# the file arch's dbs name for it, which pacman checks against arch's keyring on the way into the pool
assemble() {
  local path base name file repo list root=$WORK/official pending=() download=()
  declare -A proposed=() proposed_owner=()
  load_db_index "$OUTBOX_DB" || { held_back="the proposed db cannot be read"; return 0; }
  for name in "${!db_file[@]}"; do proposed[$name]=${db_file[$name]}; done
  for path in "$OUTBOX_STATE"/*; do
    base=$(basename "$path")
    if ! [[ $base =~ $NAME_PATTERN ]] || ! outbox_file_check "$path"; then continue; fi
    for name in $(state_get_from "$OUTBOX_STATE" "$base" names); do proposed_owner[$name]=$base; done
  done
  final=()
  for name in "${!proposed[@]}"; do
    file=${proposed[$name]}
    if [ "${state_file[$file]:-}" = "$name" ] || [ "${served[$name]:-}" = "$file" ]; then
      final[$name]=$file
    elif [ -n "${owner_of[$name]:-}${proposed_owner[$name]:-}" ]; then
      if [ -n "${served[$name]:-}" ]; then
        log "$name: $file is not signed, keeping ${served[$name]}"
        final[$name]=${served[$name]}
      else
        log "$name: $file is not signed, left out"
      fi
    else
      pending+=("$name")
    fi
  done
  log "assemble: ${#proposed[@]} names proposed, ${#pending[@]} official files new"
  (( ${#pending[@]} > 0 )) || return 0
  dbpath_create "$root"
  for repo in "${OFFICIAL_REPOS[@]}"; do
    outbox_file_check "$OUTBOX_SYNC/$repo.db" || { held_back="the outbox has no $repo db"; return 0; }
    cp "$OUTBOX_SYNC/$repo.db" "$root/sync/"
  done
  if ! pacman --dbpath "$root" -Spdd --noconfirm --print-format '%r %n %f' "${pending[@]}" > "$WORK/official.txt"; then
    list="${pending[*]}"
    held_back="proposed names that are neither built nor official: ${list:0:HELD_BACK_QUOTE_MAX}"
    return 0
  fi
  while read -r repo name file; do
    [ "${proposed[$name]:-}" = "$file" ] || { held_back="$name: proposed ${proposed[$name]:-nothing}, $repo has $file"; return 0; }
    final[$name]=$file
    download+=("$repo/$name")
  done < "$WORK/official.txt"
  # pacman checks every file against its db entry and arch's keyring, the pool's and the outbox's copies
  # included, and fetches what neither holds; a .sig next to a file says nothing, pacman may have put arch's there
  if ! pacman --dbpath "$root" -Swdd --noconfirm --cachedir "$REPO_DIR" --cachedir "$OUTBOX_POOL" "${download[@]}" \
    > "$WORK/download.log" 2>&1; then
    cat "$WORK/download.log"
    held_back="downloading or checking the official packages failed"
    return 0
  fi
  while read -r repo name file; do
    if [ ! -f "$REPO_DIR/$file" ]; then
      outbox_file_check "$OUTBOX_POOL/$file" || { held_back="$file is in no cache after the download"; return 0; }
      put "$OUTBOX_POOL/$file" "$REPO_DIR"
    fi
    sign "$REPO_DIR/$file"
  done < "$WORK/official.txt"
}

# the served db plus what changed, every added file carrying a signature of the repo key
db_assemble() {
  local name remove=() add=()
  db_copy_served "$WORK/db"
  load_db_index "$WORK/db/$REPO.db.tar.gz"
  for name in "${!db_file[@]}"; do
    [ -n "${final[$name]:-}" ] || remove+=("$name")
  done
  for name in "${!final[@]}"; do
    [ "${db_file[$name]:-}" != "${final[$name]}" ] || continue
    gpg --batch --verify "$REPO_DIR/${final[$name]}.sig" "$REPO_DIR/${final[$name]}" 2>/dev/null \
      || { held_back="${final[$name]} has no valid signature"; return 0; }
    add+=("$REPO_DIR/${final[$name]}")
  done
  log "db: ${#add[@]} added, ${#remove[@]} removed"
  (( ${#remove[@]} == 0 )) || repo-remove -q "$WORK/db/$REPO.db.tar.gz" "${remove[@]}"
  (( ${#add[@]} == 0 )) || repo-add -q "$WORK/db/$REPO.db.tar.gz" "${add[@]}"
}

# what a client with [lsck0] above everything sees: the listed and built names resolve from it alone
snapshot_verify() {
  local root=$WORK/verify targets=()
  mapfile -t targets < <(jq -r '.targets[]' "$OUTBOX_REPORT")
  (( ${#targets[@]} > 0 )) || { held_back="the proposal names no targets"; return 0; }
  dbpath_create "$root"
  cp "$WORK/db/$REPO.db.tar.gz" "$root/sync/$REPO.db"
  printf '[options]\nArchitecture = auto\nSigLevel = Never\n\n[%s]\nServer = file://%s\n' "$REPO" "$REPO_DIR" > "$root/pacman.conf"
  if ! pacman --config "$root/pacman.conf" --dbpath "$root" -Sp --noconfirm "${targets[@]}" >/dev/null 2> "$WORK/verify.log"; then
    cat "$WORK/verify.log"
    held_back="the set does not resolve from $REPO alone"
  fi
}

# the gate (header, Completeness): no listed name the served db provides may go missing
completeness_check() {
  local lost=() list
  proposed_missing=$(listed_missing "$WORK/db/$REPO.db.tar.gz") || { log "checking the proposed db against the list failed"; exit 1; }
  mapfile -t lost < <(LC_ALL=C comm -23 <(echo "$proposed_missing") <(echo "$snapshot_missing") | sed '/^$/d')
  (( ${#lost[@]} > 0 )) || return 0
  list="${lost[*]}"
  held_back="listed names the served snapshot has and this one lacks: ${list:0:HELD_BACK_QUOTE_MAX}"
}

# -----------------------------------------------------------------------------
# PUBLISH: PUBLISH
# db, signature and pacman's names for both into a directory, by put (copy) or link_into (hardlink)
db_put() {
  local op=$1 from=$2 dir=$3 f
  for f in "${DB_FILES[@]}"; do
    "$op" "$from/$f.sig" "$dir"
    "$op" "$from/$f" "$dir"
  done
  symlink_set "$REPO.db.tar.gz" "$dir/$REPO.db"
  symlink_set "$REPO.db.tar.gz.sig" "$dir/$REPO.db.sig"
  symlink_set "$REPO.files.tar.gz" "$dir/$REPO.files"
  symlink_set "$REPO.files.tar.gz.sig" "$dir/$REPO.files.sig"
}

# <date>/x86_64 hardlinks every file of the db, and current moves to it only once it is whole; a second
# publish the same day updates that day's snapshot in place, file by file like x86_64/
snapshot_publish() {
  local dir=$SERVED/$SNAPSHOT/$ARCH file manifest=$WORK/$SNAPSHOT_MANIFEST
  declare -A keep=()
  mkdir -p "$dir"
  for file in "${final[@]}"; do
    keep[$file]=1
    [ -e "$dir/$file" ] || ln "$REPO_DIR/$file" "$dir/$file"
    [ -e "$dir/$file.sig" ] || ln "$REPO_DIR/$file.sig" "$dir/$file.sig"
  done
  db_put put "$WORK/db" "$dir"
  jq -n --arg date "$SNAPSHOT" --arg started "$STARTED" --arg published "$(date -u "$TIME_FORMAT")" \
    --arg source "$SOURCE" --arg ref "$REF" --arg commit "$COMMIT" --arg key "$KEY" --argjson packages "${#final[@]}" \
    '{ date: $date, started: $started, published: $published, source: $source, ref: $ref, commit: $commit,
       signing_key: $key, packages: $packages }' > "$manifest"
  sign "$manifest"
  put "$manifest.sig" "$SERVED/$SNAPSHOT"
  put "$manifest" "$SERVED/$SNAPSHOT"
  symlink_set "$SNAPSHOT" "$SNAPSHOT_CURRENT"
  for file in "$dir"/*.pkg.tar.zst; do
    [ -n "${keep[$(basename "$file")]:-}" ] || rm -f "$file" "$file.sig"
  done
}

db_publish() {
  local f
  for f in "${DB_FILES[@]}"; do
    sign "$WORK/db/$f"
  done
  snapshot_publish
  # x86_64/ is the pool and the newest db at once, what every client without a pin reads
  db_put link_into "$SERVED/$SNAPSHOT/$ARCH" "$REPO_DIR"
}

# superseded, removed and held back files leave the pool once no served db references them; the
# dated snapshots keep their hardlinks
prune_files() {
  local file
  declare -A referenced=()
  for file in "${final[@]}"; do referenced[$file]=1; done
  for file in "$REPO_DIR"/*.pkg.tar.zst; do
    [ -n "${referenced[$(basename "$file")]:-}" ] || rm -f "$file" "$file.sig"
  done
}

snapshot_prune() {
  local dir cutoff current
  cutoff=$(date -u -d "@$(( RUN_STARTED - SNAPSHOT_KEEP_DAYS * SECONDS_PER_DAY ))" "$DATE_FORMAT")
  current=$(readlink "$SNAPSHOT_CURRENT")
  for dir in "$SERVED"/$SNAPSHOT_GLOB; do
    [[ $(basename "$dir") < $cutoff ]] && [ "$(basename "$dir")" != "$current" ] || continue
    log "removing snapshot $(basename "$dir")"
    rm -rf "$dir"
  done
}

# -----------------------------------------------------------------------------
# PUBLISH: STATUS
write_status() {
  local failures=() missing_names=() now packages official dropped snapshot
  now=$(date -u "$TIME_FORMAT")
  mapfile -t missing_names < <(sed '/^$/d' <<<"$snapshot_missing")
  packages=${#served[@]}
  snapshot=
  if [ -z "$held_back" ]; then
    packages=${#final[@]}
    snapshot=$SNAPSHOT
  fi
  official=$(jq -r '.official' "$OUTBOX_REPORT")
  dropped=$(jq -r '.dropped | join(" ")' "$OUTBOX_REPORT")
  mapfile -t failures < <({ jq -r '.failed[]' "$OUTBOX_REPORT"; failures_list; } | sort -u | sed '/^$/d')
  {
    echo "last build: $now"
    echo "source:     $SOURCE $REF $COMMIT"
    echo "snapshot:   ${snapshot:-none, held back}"
    echo "packages:   $packages"
    echo "official:   $official"
    echo "published:  ${held_back:+no, held back: }${held_back:-yes}"
    echo "built:      ${built[*]:-none}"
    echo "dropped:    ${dropped:-none}"
    echo "failed:     ${#failures[@]}"
    (( ${#failures[@]} == 0 )) || printf '  %s\n' "${failures[@]}"
    echo "missing:    ${#missing_names[@]} listed, not in the served snapshot"
    (( ${#missing_names[@]} == 0 )) || printf '  %s\n' "${missing_names[@]}"
  } > "$WORK/status.txt"
  jq -n --arg last_build "$now" --arg commit "$COMMIT" --argjson packages "$packages" --arg held_back "$held_back" \
    --arg snapshot "$snapshot" --argjson dropped "$(jq '.dropped' "$OUTBOX_REPORT")" \
    --argjson missing "$(json_array "${missing_names[@]}")" \
    --args '{ packages: $packages, failing: ($ARGS.positional | length), last_build: $last_build, commit: $commit,
      snapshot: (if $snapshot == "" then null else $snapshot end),
      held_back: (if $held_back == "" then null else $held_back end), failed: $ARGS.positional, dropped: $dropped,
      missing: $missing, running: null }' \
    "${failures[@]}" > "$WORK/status.json"
  put "$WORK/status.json" "$SERVED"
  put "$WORK/status.txt" "$SERVED"
  # archbuild-if-stale ages the run from its start, a long night must not skip the next one
  touch -d "@$RUN_STARTED" "$SERVED/status.txt"
  cat "$WORK/status.txt"
}

# -H: the dated snapshots are hardlinks of the pool there too; pacman -Sw --cachedir leaves download-* dirs
push_rsync() { rsync -aH --exclude 'download-*' --exclude '/.state/' -e "$PUSH_SSH" "$@"; }

# mirror to the always-on dmz host: packages and snapshot dirs, then the dbs and current, then the
# status, then deletions; a failure fails the unit, the mirror keeps its last whole copy
push() {
  [ -n "$PUSH_TARGET" ] && [ -f "$PUSH_KEY_FILE" ] || return 0
  [ -f "$REPO_DIR/$REPO.db" ] || return 0
  log "pushing the repo to $PUSH_TARGET"
  if push_rsync --exclude "$REPO.db*" --exclude "$REPO.files*" --exclude '/current' --exclude '/status.*' "$SERVED/" "$PUSH_TARGET/" \
    && push_rsync --delay-updates --exclude '/status.*' "$SERVED/" "$PUSH_TARGET/" \
    && push_rsync "$SERVED/status.txt" "$SERVED/status.json" "$PUSH_TARGET/" \
    && push_rsync --delete "$SERVED/" "$PUSH_TARGET/"; then
    return 0
  fi
  log "push to $PUSH_TARGET failed, the dmz mirror keeps its last copy"
  push_failed=1
}

# -----------------------------------------------------------------------------
# MAIN
build_main() {
  local base done=0
  log "setting up the build"
  setup_build
  db_stage
  setup_build_pacman
  log "resolving the package list of $DOTFILES at $COMMIT"
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
  write_progress proposing "" "$done"
  drop_unresolvable
  if snapshot_official; then
    prune_db
  fi
  [ -z "$held_back" ] || log "held back: $held_back"
  outbox_write
  clean_caches
  log "proposed ${#db_file[@]} packages, ${#built[@]} built"
}

publish_main() {
  local base
  log "setting up the publish"
  STATE_DIR=$SERVED_STATE_DIR
  outbox_check
  rm -rf "$WORK"
  mkdir -p "$WORK" "$REPO_DIR" "$STATE_DIR"
  setup_key
  setup_publish_pacman
  served_load
  # read before anything is signed: a list that cannot be read stops the night here, as it stops the build
  snapshot_missing=$(listed_missing "$REPO_DIR/$REPO.db.tar.gz") || { log "checking the served db against the list failed"; exit 1; }
  held_back=$(jq -r '.held_back // empty' "$OUTBOX_REPORT")
  while read -r base; do
    base_accept "$base"
  done < <(jq -r '.built[]' "$OUTBOX_REPORT")
  [ -n "$held_back" ] || assemble
  [ -n "$held_back" ] || db_assemble
  [ -n "$held_back" ] || snapshot_verify
  [ -n "$held_back" ] || completeness_check
  if [ -z "$held_back" ]; then
    log "publishing snapshot $SNAPSHOT"
    snapshot_missing=$proposed_missing
    db_publish
    prune_files
    snapshot_prune
    state_prune
  else
    log "held back: $held_back"
  fi
  write_status
  push
  (( ! push_failed ))
}

# tests/archrepo-list.nix sources it for the completeness gate alone
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0
case ${1:-} in
  build) build_main ;;
  publish) publish_main ;;
  *) echo "usage: $0 build|publish" >&2; exit 1 ;;
esac
