#!/usr/bin/env bash
# toggle a vm group in src/instances.tf, then ./sync.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT_DIR/src/instances.tf"

MEDIA="112 128 130 134 136"
APPS="121 124 125 126"

usage() { echo "usage: $0 status | {media|apps} {on|off|onDemand} [--apply]"; exit 1; }

group_ids() {
  case "$1" in
    media) echo "$MEDIA" ;;
    apps)  echo "$APPS" ;;
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
  for g in media apps; do
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
    # replace `enabled` only inside this id's block
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
