#!/usr/bin/env bash
# record a night skipped for a third-party outage in the served status, nothing else
#
# usage: archrepo-skip.sh <served dir> <upstream> <upstreams of the build...>
#
# Runs on the vm-112 host after archbuild ended with EX_TEMPFAIL. The served snapshot, its db and the failure
# counts stay the last night's; status.json gains `unavailable` and `skipped`, which the next publish drops,
# and status.txt a `skipped:` line. status.txt keeps its mtime, so archbuild-if-stale tries again.
set -euo pipefail

# -----------------------------------------------------------------------------
# CONSTANTS
SERVED=${1:?served dir}
UPSTREAM=${2:?the unavailable upstream}
shift 2
STATUS_JSON=$SERVED/status.json
STATUS_TXT=$SERVED/status.txt
SKIPPED_PREFIX="skipped:    "
TIME_FORMAT=+%Y-%m-%dT%H:%M:%SZ

# -----------------------------------------------------------------------------
# MAIN
# the build container names the upstream: only one this build calls reaches the status and the metrics
[[ " $* " == *" $UPSTREAM "* ]] || { echo "skip: '$UPSTREAM' is none of the build's upstreams ($*)" >&2; exit 1; }
now=$(date -u "$TIME_FORMAT")

previous='{}'
[ ! -f "$STATUS_JSON" ] || previous=$(cat "$STATUS_JSON")
jq --arg upstream "$UPSTREAM" --arg now "$now" '. + { unavailable: $upstream, skipped: $now, running: null }' \
  <<<"$previous" > "$STATUS_JSON.tmp"
mv -f "$STATUS_JSON.tmp" "$STATUS_JSON"

echo "$SKIPPED_PREFIX$now, $UPSTREAM unavailable; the last snapshot keeps serving" > "$STATUS_TXT.tmp"
if [ -f "$STATUS_TXT" ]; then
  grep -v "^$SKIPPED_PREFIX" "$STATUS_TXT" >> "$STATUS_TXT.tmp" || [ "$?" -eq 1 ]
  touch -r "$STATUS_TXT" "$STATUS_TXT.tmp"
fi
mv -f "$STATUS_TXT.tmp" "$STATUS_TXT"
