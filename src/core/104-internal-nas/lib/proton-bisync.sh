#!/usr/bin/env bash
# sync the syncthing folder with its proton drive copy both ways: rclone bisync over rclone's protondrive backend
#
# usage: proton-bisync sync|resync|login     (the environment as kopia.nix's proton-bisync units set it)
#   sync    hourly (proton-bisync.timer): what changed, appeared or vanished on either side since the last run
#           reaches the other, and syncthing spreads the folder's changes to the owner's devices
#   resync  the baseline, by hand only (proton-bisync-resync): copies each side's missing files to the other and
#           deletes nothing; a file on both sides that differs takes the newer version on both, and the other
#           stays in proton's revisions or kopia's snapshots
#   login   signs rclone in (proton-bisync-login): the account from sops, the 2fa code asked for
#
# Runs on vm-104, and under ../tests/proton-bisync.nix against a local folder standing in for proton drive.
#
# rclone runs as the syncthing user (RUN_AS), so whatever it writes into the folder is syncthing's own; the rest
# (lock, checks, metric) runs as root. STATE/rclone.conf holds the proton session, which rclone refreshes in place.
#
# Guards: no sign-in, no baseline, and a missing, unmarked or empty folder (lib/source-guard.sh) fail a run before
# rclone starts. bisync itself aborts on a missing CHECK_FILE on either side (--check-access), on an empty side, and
# on a run deleting over MAX_DELETE_PERCENT of either side or changing every file, until STATE/allow-large is
# touched (--force, one run). A file changed on both sides keeps both: the newer under its name, the older renamed
# with CONFLICT_SUFFIX. A proton outage (PROBE) skips the run with the probe's status, and an hourly run finding
# another off-site run holding the proton lock skips quietly.
# no errexit: a failed rclone run is read and explained below, every step exits itself
set +e -uo pipefail

# -----------------------------------------------------------------------------
# CONSTANTS
MODE=${1:-}
SOURCE=${PROTON_BISYNC_SOURCE:?local folder}
# a path relative to the source that exists whenever the source is really there
MARKER=${PROTON_BISYNC_MARKER:?marker path below the source}
# <rclone remote>:<path>
REMOTE=${PROTON_BISYNC_REMOTE:?remote folder}
# rclone's config and bisync's listings, owned by RUN_AS
STATE=${PROTON_BISYNC_STATE:?state folder}
# rclone filter rules, a store file; bisync stores their hash beside a copy and demands a resync when they change
FILTERS=${PROTON_BISYNC_FILTERS:?filters file}
CHECK_FILE=${PROTON_BISYNC_CHECK_FILE:?check file name}
MAX_DELETE_PERCENT=${PROTON_BISYNC_MAX_DELETE_PERCENT:?share of either side one run may delete}
CONFLICT_SUFFIX=${PROTON_BISYNC_CONFLICT_SUFFIX:?suffix of a conflict loser}
# a bisync lock left by a killed run expires after this
MAX_LOCK=${PROTON_BISYNC_MAX_LOCK:?bisync lock lifetime}
# user:group of the folder's files
RUN_AS=${PROTON_BISYNC_RUN_AS:?user:group}
USERNAME_FILE=${PROTON_BISYNC_USERNAME_FILE:?proton account name file}
PASSWORD_FILE=${PROTON_BISYNC_PASSWORD_FILE:?proton account password file}
# one proton session: no two off-site runs at once
LOCK=${PROTON_BISYNC_LOCK:?lock file}
# exits 0 while proton answers, its own status (modules/upstream's unavailable) while it is down
PROBE=${PROTON_BISYNC_PROBE:?command telling whether proton is up}
# called with the unix time of a successful run
METRIC=${PROTON_BISYNC_METRIC:?command publishing the success time}
NAME=${REMOTE%%:*}
export RCLONE_CONFIG=$STATE/rclone.conf
export RCLONE_CACHE_DIR=$STATE/cache
WORK=$STATE/work
FILTERS_COPY=$STATE/filters.txt
# touch to let the next sync delete past MAX_DELETE_PERCENT once, after checking the loss is intended
ALLOW_LARGE=$STATE/allow-large

# -----------------------------------------------------------------------------
# FUNCTIONS
# a failure while proton went down is the outage's, any other this run's own
failed() { "$PROBE" || exit $?; echo "$1" >&2; exit 1; }

# what rclone writes into the folder and STATE is the folder owner's, as syncthing's own writes are
as_owner() { setpriv --reuid="${RUN_AS%%:*}" --regid="${RUN_AS#*:}" --clear-groups -- "$@"; }

# a remote section whose session rclone has not cleared (it does when a refresh fails)
signed_in() {
  grep -qxF "[$NAME]" "$RCLONE_CONFIG" 2>/dev/null && ! grep -qE '^client_refresh_token *= *$' "$RCLONE_CONFIG"
}

# bisync's listings of the last run, or their backup that --recover falls back to
has_baseline() {
  [ -n "$(find "$WORK" -maxdepth 1 \( -name '*.path1.lst' -o -name '*.path1.lst-old' \) -print -quit 2>/dev/null)" ]
}

# a fresh config holding the account; rclone signs in on first use and adds the session to it
login() {
  local user password code new=$RCLONE_CONFIG.new
  user=$(cat "$USERNAME_FILE") && password=$(cat "$PASSWORD_FILE") || exit 1
  if [ -z "$user" ] || [ -z "$password" ]; then
    echo "the proton account is not in sops yet (proton-username, proton-password): README.md, Off-site" >&2
    exit 1
  fi
  read -r -p "2FA code of $user (empty without 2FA): " code
  install -m 0600 -o "${RUN_AS%%:*}" -g "${RUN_AS#*:}" /dev/null "$new"
  printf '[%s]\ntype = protondrive\nusername = %s\n' "$NAME" "$user" > "$new"
  # the environment keeps the password out of the process list and the config
  if ! RCLONE_CONFIG=$new RCLONE_PROTONDRIVE_PASSWORD=$(rclone obscure - <<<"$password") RCLONE_PROTONDRIVE_2FA=$code \
      as_owner rclone lsd "$NAME:" >/dev/null; then
    rm -f "$new"
    echo "sign-in failed; nothing changed" >&2
    exit 1
  fi
  mv "$new" "$RCLONE_CONFIG"
  echo "signed in. a first sync needs its baseline: systemctl start proton-bisync-resync"
}

# -----------------------------------------------------------------------------
# MAIN
case $MODE in sync|resync) ;; login) login; exit ;; *) echo "usage: proton-bisync sync|resync|login" >&2; exit 2 ;; esac
[[ $MAX_DELETE_PERCENT =~ ^[0-9]+$ ]] || { echo "proton-bisync: '$MAX_DELETE_PERCENT' is no percentage" >&2; exit 2; }

exec 9>"$LOCK"
if [ "$MODE" = sync ]; then
  # an hour's run behind a repository upload that holds proton for hours skips instead of piling up
  flock -n 9 || { echo "another off-site run holds $LOCK; skipping this hour"; exit 0; }
else
  flock 9
fi

if ! signed_in; then
  echo "rclone is not signed in to proton, or its session expired: run proton-bisync-login on this host" >&2
  exit 1
fi
source_guard "$SOURCE" "$MARKER" || exit 1
if [ "$MODE" = sync ] && ! has_baseline; then
  echo "no bisync baseline yet: once both sides are as they should be, systemctl start proton-bisync-resync" >&2
  exit 1
fi
# an outage skips the run: both sides stay as they are
"$PROBE" || exit $?

as_owner mkdir -p "$WORK" "$RCLONE_CACHE_DIR" || failed "cannot create $WORK"
as_owner install -m 0644 "$FILTERS" "$FILTERS_COPY" || failed "cannot copy the filters to $FILTERS_COPY"
args=(bisync "$SOURCE" "$REMOTE" --workdir "$WORK" --filters-file "$FILTERS_COPY" --create-empty-src-dirs
  --conflict-resolve newer --conflict-loser num --conflict-suffix "$CONFLICT_SUFFIX" --suffix-keep-extension
  --resilient --recover --max-lock "$MAX_LOCK" --max-delete "$MAX_DELETE_PERCENT" --check-filename "$CHECK_FILE" -v)
if [ "$MODE" = resync ]; then
  # --check-access holds on a resync too, so the resync is what puts the check file on the remote
  [ -e "$SOURCE/$CHECK_FILE" ] || as_owner touch "$SOURCE/$CHECK_FILE" || failed "cannot create $SOURCE/$CHECK_FILE"
  as_owner rclone mkdir "$REMOTE" || failed "cannot create $REMOTE"
  # newer, not path1: rclone 1.74.4's path1 mode records a replaced newer remote file under its old modtime and
  # fails its own listing check
  args+=(--resync-mode newer)
else
  args+=(--check-access)
  [ -e "$ALLOW_LARGE" ] && args+=(--force) && echo ">>> $ALLOW_LARGE: this run may delete past $MAX_DELETE_PERCENT%"
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT
# syncthing's own modes for what rclone creates
umask 022
as_owner rclone "${args[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "$rc" != 0 ]; then
  if grep -qE 'too many deletes|all files were changed' "$log"; then
    echo ">>> nothing synced. if the loss is intended: touch $ALLOW_LARGE; systemctl start proton-bisync" >&2
  elif grep -qi 'must run --resync' "$log"; then
    echo ">>> bisync wants a new baseline: check both sides, then systemctl start proton-bisync-resync" >&2
  elif grep -q "$CHECK_FILE" "$log"; then
    echo ">>> $CHECK_FILE must sit in both roots: restore the missing one, or run proton-bisync-resync" >&2
  fi
  failed "bisync failed (rclone exit $rc)"
fi
rm -f "$ALLOW_LARGE"
"$METRIC" "$(date +%s)"
