#!/usr/bin/env bash
# Turn a group of VMs on or off in src/instances.tf, then deploy with ./sync.sh.
#
# The lab does not have the RAM to run every group at once, so groups are
# brought up one at a time: verify one, switch it off, switch the next on.
#
#   src/scripts/stack.sh status
#   src/scripts/stack.sh media off
#   src/scripts/stack.sh apps on
#   src/scripts/stack.sh apps on --apply     # write the file
#
# Dry run by default: prints the changes it would make.
#
# Groups (ids as of the 116-internal-github-runner renumbering):
#   media   qbittorrent, tor-router and the whole *arr/Jellyfin/Kavita chain
#   apps    the personal apps that are off while the media stack is under test
#   gpu     Hermes; needs the host to bind the RTX 2060 to vfio-pci first, so it
#           is never switched on by `apps`
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT_DIR/src/instances.tf"

MEDIA="111 112 128 129 130 131 132 133 134 135 136 137"
APPS="118 119 120 122 123 125 126 127"
GPU="113"

usage() { echo "usage: $0 status | {media|apps|gpu} {on|off|onDemand} [--apply]"; exit 1; }

group_ids() {
  case "$1" in
    media) echo "$MEDIA" ;;
    apps)  echo "$APPS" ;;
    gpu)   echo "$GPU" ;;
    *) usage ;;
  esac
}

state_of() { # id -> current `enabled` value
  awk -v id="\"$1\" = {" '
    index($0, id) { found = 1 }
    found && /enabled[[:space:]]*=/ {
      gsub(/.*enabled[[:space:]]*=[[:space:]]*/, ""); gsub(/,.*/, ""); gsub(/"/, "")
      print; exit
    }' "$TF"
}

name_of() {
  awk -v id="\"$1\" = {" '
    index($0, id) { found = 1 }
    found && /name[[:space:]]*=/ { gsub(/.*name[[:space:]]*=[[:space:]]*"/, ""); gsub(/".*/, ""); print; exit }' "$TF"
}

[ $# -ge 1 ] || usage

if [ "$1" = status ]; then
  for g in media apps gpu; do
    printf '%s:\n' "$g"
    for id in $(group_ids "$g"); do
      printf '  %-4s %-34s %s\n' "$id" "$(name_of "$id")" "$(state_of "$id")"
    done
  done
  exit 0
fi

[ $# -ge 2 ] || usage
GROUP="$1"; WANT="$2"; APPLY=0
[ "${3:-}" = "--apply" ] && APPLY=1
case "$WANT" in on) VALUE=true ;; off) VALUE=false ;; onDemand) VALUE='"onDemand"' ;; *) usage ;; esac

CHANGED=0
for id in $(group_ids "$GROUP"); do
  cur=$(state_of "$id")
  [ -n "$cur" ] || { echo "WARNING: no entry for id $id in instances.tf"; continue; }
  want_bare=${VALUE//\"/}
  if [ "$cur" = "$want_bare" ]; then
    printf '  %-4s %-34s already %s\n' "$id" "$(name_of "$id")" "$cur"
    continue
  fi
  printf '  %-4s %-34s %s -> %s\n' "$id" "$(name_of "$id")" "$cur" "$want_bare"
  CHANGED=1
  if [ "$APPLY" = 1 ]; then
    # replace `enabled = <x>,` only inside this id's block: the first such line
    # after the `"<id>" = {` header.
    python3 - "$TF" "$id" "$VALUE" <<'PY'
import re, sys
path, vm_id, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
start = text.index(f'"{vm_id}" = {{')
m = re.compile(r'(enabled\s*=\s*)("onDemand"|true|false)').search(text, start)
assert m, f"no enabled field after {vm_id}"
open(path, "w").write(text[:m.start()] + m.group(1) + value + text[m.end():])
PY
  fi
done

[ "$CHANGED" = 1 ] || { echo "nothing to change."; exit 0; }
if [ "$APPLY" = 1 ]; then
  echo "src/instances.tf updated. Deploy with ./sync.sh"
else
  echo "dry run. Re-run with --apply to write src/instances.tf."
fi
