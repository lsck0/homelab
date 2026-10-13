#!/usr/bin/env bash
# sync the syncthing folder with its proton drive copy both ways through proton's own drive cli
#
# usage: proton-bisync sync|resync     (the environment as kopia.nix's proton-bisync units set it)
#   sync    hourly (proton-bisync.timer): what changed, appeared or vanished on either side since the last run
#           reaches the other, and syncthing spreads the folder's changes to the owner's devices
#   resync  the baseline, by hand only (proton-bisync-resync): every remote folder read, both sides merged, nothing
#           deleted; a file on both sides that differs keeps both versions
#
# Runs on vm-104, and under ../tests/proton-bisync.nix against a fake cli. This front holds the proton lock and
# refuses what must not sync: no proton session, a missing, unmarked or empty folder (lib/source-guard.sh), a sync
# without its baseline; a proton outage (PROBE) skips the run with the probe's status, and an hourly run finding
# another off-site run holding the lock skips quietly. proton-bisync-engine (proton-bisync.py, whose header says how
# the sync works) does the rest. A run that would delete past the limit syncs nothing until STATE/allow-large is
# touched, for one run.
# no errexit: the engine's status is read below
set +e -uo pipefail

# -----------------------------------------------------------------------------
# CONSTANTS
MODE=${1:-}
SOURCE=${PROTON_BISYNC_SOURCE:?local folder}
# a path relative to the source that exists whenever the source is really there
MARKER=${PROTON_BISYNC_MARKER:?marker path below the source}
# the engine's state and allow-large
STATE=${PROTON_BISYNC_STATE:?state folder}
# the cli's session, written by proton-drive-login
SESSION=${PROTON_BISYNC_SESSION:?proton session file}
# one proton session: no two off-site runs at once
LOCK=${PROTON_BISYNC_LOCK:?lock file}
# exits 0 while proton answers, its own status (modules/upstream's unavailable) while it is down
PROBE=${PROTON_BISYNC_PROBE:?command telling whether proton is up}
# called with the unix time of a successful run
METRIC=${PROTON_BISYNC_METRIC:?command publishing the success time}
# touch to let the next sync delete past the engine's limit once, after checking the loss is intended
ALLOW_LARGE=$STATE/allow-large
# the engine's status for a run refused by that limit
EXIT_GUARD=3

# -----------------------------------------------------------------------------
# MAIN
case $MODE in sync|resync) ;; *) echo "usage: proton-bisync sync|resync" >&2; exit 2 ;; esac

exec 9>"$LOCK"
if [ "$MODE" = sync ]; then
  # an hour's run behind a repository upload that holds proton for hours skips instead of piling up
  flock -n 9 || { echo "another off-site run holds $LOCK; skipping this hour"; exit 0; }
else
  flock 9
fi

if [ ! -s "$SESSION" ]; then
  echo "no proton session: run proton-drive-login on this host once (opens a sign-in url)" >&2
  exit 1
fi
source_guard "$SOURCE" "$MARKER" || exit 1
if [ "$MODE" = sync ] && [ ! -s "$STATE/state.json" ]; then
  echo "no baseline yet: once both sides are as they should be, systemctl start proton-bisync-resync" >&2
  exit 1
fi
# an outage skips the run: both sides stay as they are
"$PROBE" || exit $?

allow=0
if [ "$MODE" = sync ] && [ -e "$ALLOW_LARGE" ]; then
  allow=1
  echo ">>> $ALLOW_LARGE: this run may delete past the limit"
fi
PROTON_BISYNC_ALLOW_LARGE=$allow proton-bisync-engine "$MODE"
rc=$?
case $rc in
  0) rm -f "$ALLOW_LARGE"; "$METRIC" "$(date +%s)" ;;
  "$EXIT_GUARD")
    echo ">>> nothing synced. if the loss is intended: touch $ALLOW_LARGE; systemctl start proton-bisync" >&2
    exit 1 ;;
  *) exit "$rc" ;;
esac
