#!/usr/bin/env bash
# lib/prune.sh as activation runs it, generation after generation, on a scratch textfile directory
#
# usage: prune_test.sh <lib/prune.sh>
set -euo pipefail

PRUNE=${1:?prune.sh}
D=$(mktemp -d)/textfile
fail() { echo "FAIL: $*" >&2; exit 1; }
put() { for name in "$@"; do echo "x 1" > "$D/$name.prom"; done; }
has() { [ -e "$D/$1.prom" ] || fail "$2: $1.prom is gone"; }
gone() { [ ! -e "$D/$1.prom" ] || fail "$2: $1.prom is still there"; }
activate() { bash "$PRUNE" "$D" "$@" > /dev/null; }

# a host's first generation with the primitive: what nobody ever declared survives, a forgotten writer loses nothing
mkdir -p "$D"
put app_builder ondemand
activate ondemand
has app_builder "never declared"
has ondemand "declared"

# the builder moved away: the name its old generation recorded goes, the others stay
activate app_builder ondemand
activate ondemand
gone app_builder "undeclared after being declared"
has ondemand "still declared"

# a runtime part: every file of a declared pattern stays, all of them go with the pattern, and a half-written file too
activate ondemand 'swarm_app_*'
put swarm_app_hello swarm_app_wat
echo "x 1" > "$D/swarm_app_gone.prom.tmp"
activate ondemand 'swarm_app_*'
has swarm_app_hello "pattern still declared"
has swarm_app_wat "pattern still declared"
activate ondemand
gone swarm_app_hello "pattern undeclared"
gone swarm_app_wat "pattern undeclared"
[ ! -e "$D/swarm_app_gone.prom.tmp" ] || fail "pattern undeclared: its .prom.tmp is still there"

# a host that declares nothing any more removes what it recorded, and the next run removes nothing
activate
gone ondemand "nothing declared"
put ondemand
activate
has ondemand "recorded nothing last time"

# the record itself is no metric, and a pattern never matches more than its own name
activate 'db_dump_*'
put db_dump_paperless db_dumpling
activate
gone db_dump_paperless "pattern undeclared"
has db_dumpling "outside the pattern"
[ -f "$D/.declared" ] || fail "no record"

echo "prune: ok"
