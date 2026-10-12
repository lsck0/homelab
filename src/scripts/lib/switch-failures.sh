#!/usr/bin/env bash
# on a guest whose switch-to-configuration failed, with its output on stdin: what failed it, nothing when only units
# no configuration declares failed. A transient unit (podman's healthcheck runs, systemd-run) fails mid-restart by
# design, and one systemd already collected is not found any more, which no declared unit ever is. sync.sh and
# instances/preconfigured/213-external-share/tests/share.nix judge a switch by it.
set -euo pipefail

FAILED_PREFIX="warning: the following units failed: "

units=$(sed -n "s/^$FAILED_PREFIX//p" | tr ',' ' ')
if [ -z "$units" ]; then
  echo "the switch itself"
  exit 0
fi
for unit in $units; do
  if [ "$(systemctl show -P Transient -- "$unit")" = no ] && [ "$(systemctl show -P LoadState -- "$unit")" != not-found ]; then
    echo "$unit"
  fi
done
