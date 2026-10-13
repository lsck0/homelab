#!/usr/bin/env bash
# mirror one local folder to proton drive with proton's own cli: upload what is new, prune what vanished
#
# usage: PROTON_MIRROR_SOURCE=/srv/nas/BACKUPS/kopia PROTON_MIRROR_TARGET=/my-files/homelab-offsite/BACKUPS ... \
#          proton-mirror
#
# Runs on vm-104 for proton-sync (the kopia repository) and proton-sync-share (the syncthing folder), whose units
# in kopia.nix set the environment, and under ../tests/proton-mirror.nix against a fake cli. The source lands at
# <target>/<basename of source>. Two modes:
#   blobs  the kopia repository: content-addressed files only, uploaded as they are. A vanished file is trashed by
#          path, then deleted from the trash by its name, which no other trashed item shares.
#   tree   plain files (the syncthing folder): staged first as hard links minus the excludes, so the upload sees a
#          still tree and none of syncthing's internals. Files and folders are tracked; only the topmost vanished
#          item of a subtree is pruned, renamed to a unique name first so the trash delete cannot hit another item.
#
# The cli (0.8.0) has no mirror mode, so the manifest (paths earlier runs uploaded, or failed to prune) is the only
# memory of what is remote: lose it and the remote keeps what was deleted before. An upload's verdict comes from the
# cli's json summary (-j, the last stdout line), never from the log text, where a warning shaped like an item error
# would flip it: sockets and symlinks are expected skips, a file changed mid-upload gets one more try.
#
# Guards: a missing source, a source without its marker (the kopia repository's format blob, syncthing's .stfolder:
# an unmounted or wiped folder) or with nothing beside the marker is refused, never read as "everything deleted";
# a run that would prune more than MAX_GONE_PERCENT of the manifest stops until <manifest>.allow-large is touched.
# A proton outage (PROBE) skips the run with the probe's status: the off-site copy stays as it was.
# no errexit: a failed batch must not skip the rest, every step sets ok or exits itself
set +e -uo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# CONSTANTS
MODE=${PROTON_MIRROR_MODE:?blobs or tree}
SOURCE=${PROTON_MIRROR_SOURCE:?local folder to mirror}
# the remote folder the source is uploaded into, a posix path below /my-files
TARGET=${PROTON_MIRROR_TARGET:?remote parent folder}
# the remote root every mirror lives below, and the names it keeps there: anything else is an earlier version's
ROOT=${PROTON_MIRROR_ROOT:?remote root folder}
read -r -a ROOT_KEEP <<<"${PROTON_MIRROR_ROOT_KEEP:?names the remote root keeps}"
# a path relative to the source that exists whenever the source is really there
MARKER=${PROTON_MIRROR_MARKER:?marker path below the source}
MANIFEST=${PROTON_MIRROR_MANIFEST:?manifest file}
MAX_GONE_PERCENT=${PROTON_MIRROR_MAX_GONE_PERCENT:?share of the manifest one run may prune}
# rsync patterns left out of a tree mirror, one per word
read -r -a EXCLUDES <<<"${PROTON_MIRROR_EXCLUDES:-}"
# the cli's home: its session, the shared purge queue and the stage
STATE=${PROTON_MIRROR_STATE:?proton drive state folder}
# one proton session: no two runs of the cli at once
LOCK=${PROTON_MIRROR_LOCK:?lock file}
# exits 0 while proton answers, its own status (modules/upstream's unavailable) while it is down
PROBE=${PROTON_MIRROR_PROBE:?command telling whether proton is up}
# called with the unix time of a fully successful run
METRIC=${PROTON_MIRROR_METRIC:?command publishing the success time}
# paths per trash or delete call: the cli lists each path's folder, so a bound keeps a call's runtime and argv small
BATCH_COUNT=100
NAME=$(basename "$SOURCE")
REMOTE=$TARGET/$NAME
SESSION=$STATE/auth-session.json
# touch to let the next run prune past MAX_GONE_PERCENT once, after checking the loss is intended
ALLOW_LARGE=$MANIFEST.allow-large
# remote names trashed but not yet deleted from the trash, shared by every mirror
PURGE_QUEUE=$STATE/offsite-purge.txt
STAGE=$STATE/stage

# -----------------------------------------------------------------------------
# FUNCTIONS
# a failure while proton went down is the outage's, any other this run's own
failed() { "$PROBE" || exit $?; echo "$1" >&2; exit 1; }

# remote parents must exist before an upload; create-folder refuses an existing one
folder_ensure() { # <parent> <name>
  proton-drive filesystem list -j "$1" | jq -e --arg n "$2" 'any(.[]; .name.value == $n)' >/dev/null \
    || proton-drive filesystem create-folder "$1" "$2" >/dev/null
}

# every folder of TARGET below /my-files, outermost first
target_ensure() {
  local parent=/my-files part
  local -a parts
  IFS=/ read -r -a parts <<<"${TARGET#/my-files/}"
  for part in "${parts[@]}"; do
    folder_ensure "$parent" "$part" || return 1
    parent=$parent/$part
  done
}

# 0 uploaded, 2 only files changed mid-upload (retry once), 1 anything else; unchanged files are skipped by hash
upload() { # <local path> <remote parent>
  local out err rc real summary
  out=$(mktemp); err=$(mktemp)
  proton-drive filesystem upload -j -f create-new-revision -d merge -t "$1" "$2" > "$out" 2> "$err"
  rc=$?
  cat "$err" >&2
  summary=$(tail -n 1 "$out")
  rm -f "$out" "$err"
  [ "$rc" = 0 ] && return 0
  # no summary is the call itself failing: session expired, network down
  jq -e '.failures | type == "array"' <<<"$summary" >/dev/null 2>&1 || return 1
  echo ">>> upload failures: $(jq -c '.failures' <<<"$summary")" >&2
  real=$(jq -c '[.failures[].error | select(contains("Not a regular file or directory") | not)]' <<<"$summary")
  [ "$real" = "[]" ] && return 0
  jq -e 'all(.[]; startswith("IntegrityError"))' <<<"$real" >/dev/null && return 2
  return 1
}

# runs `filesystem <verb>` on the paths, prints those still there; gone_pattern in the error means already gone
remote_apply() { # <verb> <gone pattern> <path>...
  local verb=$1 gone_pattern=$2 out err item
  shift 2
  err=$(mktemp)
  if out=$(proton-drive filesystem "$verb" -j "$@" 2>"$err") && jq -e 'all(.[]; .ok == true)' <<<"$out" >/dev/null 2>&1; then
    rm -f "$err"
    return 0
  fi
  # one unresolvable path fails the whole call before anything moves: retry one by one
  for item in "$@"; do
    if out=$(proton-drive filesystem "$verb" -j "$item" 2>"$err") && jq -e 'all(.[]; .ok == true)' <<<"$out" >/dev/null 2>&1; then continue; fi
    grep -q "$gone_pattern" "$err" && continue
    echo ">>> $verb $item failed: $(head -c 300 "$err") $(head -c 300 <<<"$out")" >&2
    echo "$item"
  done
  rm -f "$err"
}

# remote_apply over stdin's lines in batches of BATCH_COUNT
remote_apply_batched() { # <verb> <gone pattern>
  local verb=$1 gone_pattern=$2 i
  local -a items
  mapfile -t items
  for ((i = 0; i < ${#items[@]}; i += BATCH_COUNT)); do
    remote_apply "$verb" "$gone_pattern" "${items[@]:i:BATCH_COUNT}"
  done
}

# renames each stdin path (relative to <base>, a folder with its trailing /) to a name unique in the trash, then
# trashes it and queues it for deletion; prints the paths still remote, a renamed one under its new name
trash_unique() { # <base>
  local base=$1 rel unique err renamed
  err=$(mktemp); renamed=$(mktemp)
  while IFS= read -r rel; do
    unique="homelab-offsite-gone-$(date +%s%N)"
    if proton-drive filesystem rename "$base/${rel%/}" "$unique" </dev/null >/dev/null 2>"$err"; then
      printf '%s\t%s\n' "$unique" "$rel" >> "$renamed"
    elif ! grep -q 'Node not found' "$err"; then
      echo ">>> rename $base/$rel failed: $(head -c 300 "$err")" >&2
      echo "$rel"
    fi
  done
  while IFS=$'\t' read -r unique rel; do
    echo "$base/$(dirname "$rel")/$unique"
  done < "$renamed" | sed 's|/\./|/|' | remote_apply_batched trash 'Node not found' | sed "s|^$base/||" > "$err"
  # the untrashed stay in the manifest under their new names, so the next run prunes them
  cut -f 1 "$renamed" | grep -vxF -f <(sed 's|.*/||' "$err") >> "$PURGE_QUEUE"
  cat "$err"
  rm -f "$err" "$renamed"
}

# the source's entries relative to it, sorted: files in blobs mode, files and folders (trailing /) in tree mode
entries_list() { # <dir>
  if [ "$MODE" = blobs ]; then
    find "$1" -type f -printf '%P\n'
  else
    find "$1" -mindepth 1 \( -type d -printf '%P/\n' \) -o \( -type f -printf '%P\n' \)
  fi | LC_ALL=C sort
}

# of a sorted path list, only the items no listed folder contains: a prefix's paths sort together, the folder first
topmost() { awk 'top != "" && index($0, top) == 1 { next } { print; top = /\/$/ ? $0 : "" }'; }

# trashes the gone entries below REMOTE, queues them for deletion, prints those still remote
prune() { # <gone file>
  local failed
  if [ "$MODE" = tree ]; then
    topmost < "$1" | trash_unique "$REMOTE"
    return
  fi
  failed=$(mktemp)
  sed "s|^|$REMOTE/|" "$1" | remote_apply_batched trash 'Node not found' | sed "s|^$REMOTE/||" > "$failed"
  # blob names are content hashes, unique in the trash, so deleting by name cannot hit another item
  LC_ALL=C comm -23 "$1" <(LC_ALL=C sort "$failed") | sed 's|.*/||' >> "$PURGE_QUEUE"
  cat "$failed"
  rm -f "$failed"
}

# -----------------------------------------------------------------------------
# MAIN
case $MODE in blobs|tree) ;; *) echo "proton-mirror: mode '$MODE' is neither blobs nor tree" >&2; exit 2 ;; esac
[[ $MAX_GONE_PERCENT =~ ^[0-9]+$ ]] || { echo "proton-mirror: '$MAX_GONE_PERCENT' is no percentage" >&2; exit 2; }
[[ $TARGET == /my-files/* ]] || { echo "proton-mirror: target '$TARGET' is not below /my-files" >&2; exit 2; }

exec 9>"$LOCK"
flock 9

if [ ! -s "$SESSION" ]; then
  echo "no proton session; run 'proton-drive-login' on this host once (opens a sign-in url)"
  exit 0
fi
# an unmounted or wiped source must not read as a source whose every file was deleted
if [ ! -e "$SOURCE/$MARKER" ]; then
  echo "no $MARKER in $SOURCE: missing, unmounted or wiped; refusing to sync" >&2
  exit 1
fi
if [ -z "$(find "$SOURCE" -mindepth 1 -maxdepth 1 ! -name "$(basename "$MARKER")" -print -quit)" ]; then
  echo "$SOURCE holds nothing beside $MARKER; refusing to sync" >&2
  exit 1
fi

# an outage skips the run: the off-site copy stays as the last run left it
"$PROBE" || exit $?
target_ensure || failed "cannot create the remote folders of $TARGET"

upload_from=$SOURCE
if [ "$MODE" = tree ]; then
  # hard links need one filesystem; a copy of the whole tree is no stage
  mkdir -p "$STAGE"
  [ "$(stat -c %d "$SOURCE")" = "$(stat -c %d "$STAGE")" ] || failed "$STAGE is not on $SOURCE's filesystem"
  rm -rf "${STAGE:?}/$NAME"
  trap 'rm -rf "${STAGE:?}/$NAME"' EXIT
  rsync_excludes=()
  for pattern in "${EXCLUDES[@]}"; do rsync_excludes+=(--exclude "$pattern"); done
  rsync -a --link-dest="$SOURCE" "${rsync_excludes[@]}" "$SOURCE/" "$STAGE/$NAME/" || failed "cannot stage $SOURCE"
  upload_from=$STAGE/$NAME
fi

ok=1
touch "$MANIFEST" "$PURGE_QUEUE"
current=$(mktemp)
gone=$(mktemp)
kept=$(mktemp)
# listed before the upload: a file written during it is in the next run's list and upload
entries_list "$upload_from" > "$current"
# what may be remote once the upload starts: a run cut short (timeout) still prunes it later
LC_ALL=C sort -u "$MANIFEST" "$current" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

echo ">>> $SOURCE -> $REMOTE"
upload "$upload_from" "$TARGET"
case $? in
  0) ;;
  2) echo ">>> $SOURCE changed during the upload, once more"; upload "$upload_from" "$TARGET" || ok=0 ;;
  *) ok=0 ;;
esac

LC_ALL=C comm -23 "$MANIFEST" "$current" > "$gone"
gone_count=$(wc -l < "$gone")
known_count=$(wc -l < "$MANIFEST")
if [ "$ok" != 1 ]; then
  # a failed upload says nothing good about the session or the source; prune next time
  cp "$gone" "$kept"
elif [ "$gone_count" -gt 0 ] && [ $((gone_count * 100)) -gt $((known_count * MAX_GONE_PERCENT)) ] \
    && [ ! -e "$ALLOW_LARGE" ]; then
  echo ">>> $gone_count of $known_count uploaded entries are gone locally, over $MAX_GONE_PERCENT%;"
  echo ">>> not pruning the off-site copy. if intended: touch $ALLOW_LARGE and rerun"
  cp "$gone" "$kept"
  ok=0
else
  rm -f "$ALLOW_LARGE"
  echo ">>> pruning $gone_count remote entries the source dropped"
  prune "$gone" > "$kept"
  [ -s "$kept" ] && ok=0
fi
# the next run retries what could not be pruned
LC_ALL=C sort -u "$current" "$kept" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

# whatever else sits in the remote root an earlier version uploaded
strays=$(mktemp)
proton-drive filesystem list -j "$ROOT" 2>/dev/null | jq -r '.[] | .name.value // empty' 2>/dev/null \
  | grep -vxF -f <(printf '%s\n' "${ROOT_KEEP[@]}") > "$strays"
if [ -s "$strays" ]; then
  echo ">>> trashing $(tr '\n' ' ' < "$strays")from $ROOT, uploaded by an earlier version"
  [ -z "$(trash_unique "$ROOT" < "$strays")" ] || ok=0
fi
rm -f "$strays"

if [ -s "$PURGE_QUEUE" ]; then
  echo ">>> deleting $(wc -l < "$PURGE_QUEUE") trashed entries for good"
  sed 's|^|/trash/|' "$PURGE_QUEUE" | remote_apply_batched delete 'Trashed node not found' \
    | sed 's|^/trash/||' > "$PURGE_QUEUE.tmp"
  mv "$PURGE_QUEUE.tmp" "$PURGE_QUEUE"
  [ -s "$PURGE_QUEUE" ] && ok=0
fi
rm -f "$current" "$gone" "$kept"

[ "$ok" = 1 ] || failed "one or more uploads or prunes failed"
# freshness only on a fully successful run
"$METRIC" "$(date +%s)"
