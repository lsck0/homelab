#!/usr/bin/env bash
# toggle a boot phase's guests (vm.power in their instance.nix), then ./sync.sh
#
# usage: stack.sh status
#        stack.sh <phase> on|off [--apply]     (phases: TOGGLEABLE_PHASES; without --apply a dry run)
#
# A guest is src/instances/<name>/instance.nix, the swarm's workers are the one `nodes.vm` of src/apps/swarm.nix.
# Every read and write stays inside that file: a guest without `power` has the schema's default
# (modules/instance-schema.nix), and turning it gets an explicit `power` line after its bootPhase line. Whether a
# guest idles is its instance.nix `idle`, not a group's state.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=src/scripts/lib/tools.sh
. "$ROOT_DIR/src/scripts/lib/tools.sh"
tools_require python3

exec python3 - "$ROOT_DIR/src" "$@" <<'PY'
import re
import sys
from pathlib import Path

# the toggleable groups are boot phases; the rest of the lab depends on nas, network and dev
TOGGLEABLE_PHASES = ("apps", "media", "public")
STATES = ("on", "off")
# instance folders starting with this are documentation (the template)
HIDDEN_PREFIX = "_"

src, args = Path(sys.argv[1]), sys.argv[2:]


def usage():
    print(f"usage: stack.sh status | {{{'|'.join(TOGGLEABLE_PHASES)}}} {{{'|'.join(STATES)}}} [--apply]", file=sys.stderr)
    sys.exit(2)


def field_find(text, name):
    """the match of `name = "<value>";` (or `vm.name = ...`), None when the file does not set it."""
    return re.search(rf'^(\s*)((?:vm\.)?){name}\s*=\s*"([^"]*)"\s*;', text, re.MULTILINE)


schema = (src / "modules/instance-schema.nix").read_text()
default = re.search(r'power = mkOption \{.*?default = "([^"]+)";', schema, re.DOTALL)
if default is None:
    sys.exit("ERROR: no `power` default in modules/instance-schema.nix")
POWER_DEFAULT = default.group(1)

# every guest file: name -> (path, phase, power, explicit)
guests = {}
sources = [(d.name, d / "instance.nix") for d in sorted((src / "instances").iterdir())
           if d.is_dir() and not d.name.startswith(HIDDEN_PREFIX)]
sources.append(("swarm nodes (apps/swarm.nix)", src / "apps/swarm.nix"))
for name, path in sources:
    text = path.read_text()
    phase, power = field_find(text, "bootPhase"), field_find(text, "power")
    if phase is None:
        sys.exit(f"ERROR: {path} sets no bootPhase")
    guests[name] = (path, phase.group(3), power.group(3) if power else POWER_DEFAULT, power is not None)

if not args:
    usage()
if args[0] == "status":
    if len(args) != 1:
        usage()
    for phase in TOGGLEABLE_PHASES:
        print(f"{phase}:")
        for name, (_, p, power, explicit) in guests.items():
            if p == phase:
                print(f"  {name:<34} {power}{'' if explicit else ' (default)'}")
    sys.exit(0)

if len(args) not in (2, 3) or args[0] not in TOGGLEABLE_PHASES or args[1] not in STATES:
    usage()
if len(args) == 3 and args[2] != "--apply":
    usage()
phase, want, apply = args[0], args[1], len(args) == 3

edits = []
for name, (path, p, power, explicit) in guests.items():
    if p != phase:
        continue
    if power == want:
        print(f"  {name:<34} already {power}")
        continue
    print(f"  {name:<34} {power} -> {want}")
    text = path.read_text()
    if explicit:
        m = field_find(text, "power")
        text = text[:m.start()] + f'{m.group(1)}{m.group(2)}power = "{want}";' + text[m.end():]
    else:
        m = field_find(text, "bootPhase")
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
