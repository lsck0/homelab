#!/usr/bin/env bash
# toggle a boot phase's guests (vm.power in their instance.nix), then ./sync.sh
#
# usage: stack.sh status
#        stack.sh <phase> on|off [--apply]     (phases: TOGGLEABLE_PHASES; without --apply a dry run)
#
# Every guest's phase, power and declaring file come from the collector (`nix eval .#lab.instances`); a write edits
# only that file: its `power` line, or a new one after its bootPhase line where the schema's default held. The swarm's
# workers share one file (src/apps/swarm.nix) and turn together; an app's own guest follows the app's `enable`.
# Whether a guest idles is its instance.nix `idle`, not a group's state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=src/scripts/lib/tools.sh
. "$ROOT_DIR/src/scripts/lib/tools.sh"
tools_require python3 nix

exec python3 - "$ROOT_DIR/src" "$@" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

# the toggleable groups are boot phases; the rest of the lab depends on nas, network and dev
TOGGLEABLE_PHASES = ("apps", "media", "public")
STATES = ("on", "off")
# what the collector says of each guest, the one json `nix eval` prints
INSTANCES_PROJECTION = "is: builtins.mapAttrs (_: i: { inherit (i) source; inherit (i.config.vm) bootPhase power; }) is"
APP_SOURCE_SUFFIX = "/app.nix"

src, args = Path(sys.argv[1]), sys.argv[2:]


def usage():
    print(f"usage: stack.sh status | {{{'|'.join(TOGGLEABLE_PHASES)}}} {{{'|'.join(STATES)}}} [--apply]", file=sys.stderr)
    sys.exit(2)


def field_find(text, name):
    """the match of `name = "<value>";` (or `vm.name = ...`), None when the file does not set it."""
    return re.search(rf'^(\s*)((?:vm\.)?){name}\s*=\s*"([^"]*)"\s*;', text, re.MULTILINE)


def guests_load():
    """declaring file (relative to src) -> (phase, power) of every guest stack.sh turns."""
    run = subprocess.run(["nix", "eval", "--json", "--no-warn-dirty", f"{src}#lab.instances", "--apply", INSTANCES_PROJECTION],
                         capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit(f"ERROR: the lab does not evaluate (nix eval .#lab.instances):\n{run.stderr}")
    guests = {}
    for guest in json.loads(run.stdout).values():
        if guest["source"].endswith(APP_SOURCE_SUFFIX):
            continue
        guests[guest["source"]] = (guest["bootPhase"], guest["power"])
    return guests


def guest_name(source):
    return Path(source).parent.name if source.startswith("instances/") else source


guests = guests_load()

if not args:
    usage()
if args[0] == "status":
    if len(args) != 1:
        usage()
    for phase in TOGGLEABLE_PHASES:
        print(f"{phase}:")
        for source, (p, power) in sorted(guests.items()):
            if p == phase:
                print(f"  {guest_name(source):<34} {power}")
    sys.exit(0)

if len(args) not in (2, 3) or args[0] not in TOGGLEABLE_PHASES or args[1] not in STATES:
    usage()
if len(args) == 3 and args[2] != "--apply":
    usage()
phase, want, apply = args[0], args[1], len(args) == 3

edits = []
for source, (p, power) in sorted(guests.items()):
    if p != phase:
        continue
    if power == want:
        print(f"  {guest_name(source):<34} already {power}")
        continue
    print(f"  {guest_name(source):<34} {power} -> {want}")
    path = src / source
    text = path.read_text()
    m = field_find(text, "power")
    if m is not None:
        text = text[:m.start()] + f'{m.group(1)}{m.group(2)}power = "{want}";' + text[m.end():]
    else:
        m = field_find(text, "bootPhase")
        if m is None:
            sys.exit(f"ERROR: {path} sets no bootPhase line to put `power` after")
        line_end = text.index("\n", m.end()) + 1
        text = text[:line_end] + f'{m.group(1)}{m.group(2)}power = "{want}";\n' + text[line_end:]
    edits.append((path, text))

if not edits:
    print("nothing to change.")
elif apply:
    for path, text in edits:
        path.write_text(text)
    print("instance files updated. Deploy with ./sync.sh")
else:
    print("dry run. Re-run with --apply to write the instance files.")
PY
