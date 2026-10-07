#!/usr/bin/env bash
# mirror the official arch repos (core/extra/multilib, x86_64) from a tier-1 rsync upstream into a served tree
#
# usage: ARCHMIRROR_UPSTREAM=rsync://host/archlinux/ ARCHMIRROR_TARGET=/srv/... ARCHMIRROR_BWLIMIT_KBPS=61440 \
#          archmirror-sync.sh
#
# Runs on vm-109 (archmirror-sync.service, which holds the flock; ../main.nix sets the environment), and under
# ../tests/archmirror-sync.nix against a local rsync daemon. The official two-stage method:
#   1. fetch upstream's `lastupdate` first. Byte-equal to ours (content, not mtime): nothing changed upstream, so
#      an hourly tick costs one tiny transfer, not a walk of the 120 GiB tree.
#   2. otherwise a full pass. --delay-updates stages every changed file in a .~tmp~ dir and renames the whole batch
#      into place only after a clean transfer, so nginx never serves a half-synced tree; --delete-after removes
#      stale files last. /iso and /sources are left out; the rest measured 122 GiB after the first sync (2026-10).
#   3. only after the pass succeeded, install the `lastupdate` fetched in step 1. The pass leaves ours alone
#      (excluded and protected), so an interrupted or failed pass keeps the old stamp and the next run does the full
#      pass again instead of short-circuiting on a tree it never finished. Step 1's copy, not a fresh one: upstream
#      may move on during a long pass, and a newer stamp would claim files we never fetched.
set -euo pipefail

# -----------------------------------------------------------------------------
# CONSTANTS
UPSTREAM=${ARCHMIRROR_UPSTREAM:?rsync url of the upstream module root, with a trailing slash}
TARGET=${ARCHMIRROR_TARGET:?directory the tree is mirrored into}
# KiB/s, rsync's unit for --bwlimit
BWLIMIT_KBPS=${ARCHMIRROR_BWLIMIT_KBPS:?bandwidth cap in KiB/s}
# the upstream's change marker, a unix timestamp at the module root
STAMP=lastupdate
# no data for this long aborts the pass; 10 min outlasts a busy tier-1 that stalls while it renames its own batch
IO_TIMEOUT_S=600
CONNECT_TIMEOUT_S=60

# -----------------------------------------------------------------------------
# MAIN
[[ $UPSTREAM == rsync://*/ ]] || { echo "archmirror: '$UPSTREAM' is no rsync:// module root ending in /" >&2; exit 1; }
[[ $BWLIMIT_KBPS =~ ^[1-9][0-9]*$ ]] || { echo "archmirror: bandwidth cap '$BWLIMIT_KBPS' is no positive KiB/s" >&2; exit 1; }
mkdir -p "$TARGET"

stamp_new=$(mktemp)
trap 'rm -f "$stamp_new"' EXIT
if ! rsync -q --no-motd --timeout="$IO_TIMEOUT_S" --contimeout="$CONNECT_TIMEOUT_S" "$UPSTREAM$STAMP" "$stamp_new"; then
  echo "archmirror: cannot fetch $UPSTREAM$STAMP, the mirror stays as it is" >&2
  exit 1
fi
if cmp -s "$stamp_new" "$TARGET/$STAMP"; then
  echo "archmirror: upstream unchanged, nothing to sync"
  exit 0
fi

# --safe-links drops links escaping the tree, the repos' relative links into pool/ stay; the stamp is step 3's
rsync \
  -rtlH -p --safe-links --no-motd \
  --delay-updates --delete-after --delete-excluded \
  --timeout="$IO_TIMEOUT_S" --contimeout="$CONNECT_TIMEOUT_S" \
  --bwlimit="$BWLIMIT_KBPS" \
  --filter="P /$STAMP" --exclude="/$STAMP" \
  --exclude='/iso' --exclude='/sources' --exclude='*.links.tar.gz*' \
  "$UPSTREAM" "$TARGET/"

# a rename, so a reader sees the old stamp or the new one, never a torn file; dotfiles are never served
install -m 0644 "$stamp_new" "$TARGET/.$STAMP.new"
mv -f "$TARGET/.$STAMP.new" "$TARGET/$STAMP"
echo "archmirror: synced to upstream $STAMP $(cat "$TARGET/$STAMP")"
