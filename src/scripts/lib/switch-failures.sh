#!/usr/bin/env bash
# on a guest whose switch-to-configuration failed, with its output on stdin: what failed it, nothing when only transient
# units (podman's healthcheck runs, systemd-run) failed, which belong to no configuration and fail mid-restart by design.
# sync.sh and instances/207-external-share/tests/share.nix judge a switch by it.
set -euo pipefail

FAILED_PREFIX="warning: the following units failed: "

units=$(sed -n "s/^$FAILED_PREFIX//p" | tr ',' ' ')
if [ -z "$units" ]; then
  echo "the switch itself"
  exit 0
fi
for unit in $units; do
  [ "$(systemctl show -P Transient "$unit")" = yes ] || echo "$unit"
done
