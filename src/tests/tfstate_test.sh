#!/usr/bin/env bash
# sync.sh's terraform state handling (scripts/lib/tfstate.sh) on local files: the nas is a directory, the lock a
# flock on it. A table of pull and push situations, the lock, then a seeded simulation of two deployers with failing
# pushes and nas outages whose oracle is: no apply ever disappears without a stop that names the divergence.
#
# usage: tfstate_test.sh <scripts/lib/tfstate.sh> <seed>
set -euo pipefail

LIB=${1:?tfstate.sh}
SEED=${2:?seed}
echo "seed=$SEED"
RANDOM=$SEED
# simulated sync runs; each draws a deployer and its faults from the seed
SIM_STEPS=300
# percent of pushes whose write fails, and of syncs during which the nas is down at push time
PUSH_FAIL_PERCENT=20
NAS_DOWN_PERCENT=10

# shellcheck source=src/scripts/lib/tfstate.sh
. "$LIB"
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# the transport on local files; NAS and NAS_DOWN pick the nas
# -----------------------------------------------------------------------------
tfstate_remote_read() {
  [ "${NAS_DOWN:-0}" = 1 ] && return 1
  [ -f "$NAS/state" ] || return 2
  cp "$NAS/state" "$1"
}
tfstate_remote_write() {
  [ "${NAS_DOWN:-0}" = 1 ] && return 1
  [ "${PUSH_FAILS:-0}" = 1 ] && return 1
  # the oracle: a write never drops an apply the nas holds
  if [ -f "$NAS/state" ] && ! jq -e --slurpfile new "$1" '.applies - $new[0].applies == []' "$NAS/state" >/dev/null; then
    fail "a push dropped applies $(jq -c --slurpfile new "$1" '.applies - $new[0].applies' "$NAS/state") from the nas"
  fi
  cp "$1" "$NAS/state.new" && mv "$NAS/state.new" "$NAS/state"
}
tfstate_remote_lock() {
  [ "${NAS_DOWN:-0}" = 1 ] && return 1
  flock -n "$NAS/lock" -c 'echo locked; cat >/dev/null' || echo busy
}

# state <lineage> <serial> <apply ids json>
state() { jq -n --arg l "$1" --argjson s "$2" --argjson a "$3" '{lineage: $l, serial: $s, applies: $a}'; }
# apply <file> <id>: what terraform does to a state: serial up, one more apply in it
apply() { jq --arg id "$2" '.serial += 1 | .applies += [$id]' "$1" > "$1.t" && mv "$1.t" "$1"; }

# -----------------------------------------------------------------------------
# TABLE: one situation per case, a fresh nas and local copy each
# -----------------------------------------------------------------------------
cases=0
# setup <nas state or -> <local state or -> <synced: nas|local|none|the state json both last agreed on>
setup() {
  cases=$((cases + 1))
  NAS=$T/case-$cases/nas; TFSTATE_LOCAL=$T/case-$cases/local.tfstate
  mkdir -p "$NAS"
  [ "$1" = - ] || echo "$1" > "$NAS/state"
  [ "$2" = - ] || echo "$2" > "$TFSTATE_LOCAL"
  case "$3" in
    nas) tfstate_synced_set "$NAS/state" ;;
    local) tfstate_synced_set "$TFSTATE_LOCAL" ;;
    none) ;;
    *) echo "$3" > "$T/agreed.json"; tfstate_synced_set "$T/agreed.json" ;;
  esac
}
expect_ok() { local out; out=$("$@") || fail "case $cases ($*): refused: $out"; echo "$out"; }
expect_stop() { # expect_stop <says> <cmd...>
  local says=$1 out rc=0; shift
  out=$("$@") || rc=$?
  [ "$rc" = 1 ] || fail "case $cases ($*): expected a stop, rc=$rc: $out"
  grep -qF -- "$says" <<<"$out" || fail "case $cases: the stop does not say '$says': $out"
}
local_is() { [ "$(jq -c .applies "$TFSTATE_LOCAL")" = "$1" ] || fail "case $cases: local holds $(jq -c .applies "$TFSTATE_LOCAL"), not $1"; }
nas_is() { [ "$(jq -c .applies "$NAS/state")" = "$1" ] || fail "case $cases: nas holds $(jq -c .applies "$NAS/state"), not $1"; }

S10=$(state L 10 '["a"]'); S11=$(state L 11 '["a","b"]'); S11c=$(state L 11 '["a","c"]'); S12=$(state L 12 '["a","b","d"]')

setup - - none;        expect_stop "First deploy of an empty lab" tfstate_pull; echo "ok: no state anywhere stops"
setup - - none;        TF_STATE_FRESH=1 expect_ok tfstate_pull >/dev/null; echo "ok: TF_STATE_FRESH=1 starts empty"
setup - "$S10" none;   expect_ok tfstate_pull >/dev/null; local_is '["a"]'; echo "ok: no nas state keeps the local copy"
setup "$S10" - none;   expect_ok tfstate_pull >/dev/null; local_is '["a"]'; echo "ok: a missing local copy takes the nas"
setup "$S10" "$S10" none; expect_ok tfstate_pull >/dev/null; [ "$(tfstate_synced_get)" = "$(tfstate_hash "$NAS/state")" ] \
  || fail "an equal copy did not record the agreement"; echo "ok: equal copies agree"
setup "$S10" "$S11" nas; expect_ok tfstate_pull >/dev/null; local_is '["a","b"]'; echo "ok: an unpushed local apply is kept"
setup "$S11" "$S10" local; expect_ok tfstate_pull >/dev/null; local_is '["a","b"]'; echo "ok: a newer nas replaces an unchanged local copy"
setup "$S11c" "$S11" none; expect_stop "both changed" tfstate_pull; echo "ok: same serial, other content, stops"
setup "$S11c" "$S12" none; expect_stop "both changed" tfstate_pull; echo "ok: no agreement and the local copy ahead stops"
S12c=$(state L 12 '["a","b","e"]')
setup "$S12c" "$S12" "$S11"; expect_stop "both changed" tfstate_pull; local_is '["a","b","d"]'
echo "ok: both moved on from the last agreement stops (the serial-only rule pushed over this)"
setup "$(state M 10 '["a"]')" "$S10" nas; expect_stop "lineage differs" tfstate_pull; echo "ok: another lineage stops"
setup "$S10" "$S10" nas; NAS_DOWN=1 expect_stop "does not answer" tfstate_pull; echo "ok: an unreachable nas stops the pull"

setup "$S10" "$S11" nas; expect_ok tfstate_push >/dev/null; nas_is '["a","b"]'; echo "ok: a newer local serial is pushed"
setup "$S10" "$S10" nas; expect_ok tfstate_push >/dev/null; nas_is '["a"]'; echo "ok: nothing new, nothing pushed"
setup "$S11c" "$S12" "$S11"; expect_stop "not the one this run started from" tfstate_push; nas_is '["a","c"]'; echo "ok: a nas changed under the run is not overwritten"
setup - "$S10" none; expect_ok tfstate_push >/dev/null; nas_is '["a"]'; echo "ok: the first push creates the nas state"
setup "$S10" "$S11" nas; out=$(NAS_DOWN=1 tfstate_push); grep -qF "the next sync pushes it" <<<"$out" || fail "nas down at push: $out"
nas_is '["a"]'; expect_ok tfstate_pull >/dev/null; local_is '["a","b"]'; expect_ok tfstate_push >/dev/null; nas_is '["a","b"]'
echo "ok: a push the nas missed stays ahead and goes up next run"

# -----------------------------------------------------------------------------
# LOCK
# -----------------------------------------------------------------------------
setup "$S10" "$S10" nas
tfstate_lock_acquire >/dev/null || fail "the free lock was not taken"
held_pid=$TFSTATE_LOCK_PID held_in=$TFSTATE_LOCK_IN held_out=$TFSTATE_LOCK_OUT held_dir=$TFSTATE_LOCK_DIR
out=$(tfstate_lock_acquire) && fail "a second holder got the lock"
grep -qF "another sync holds" <<<"$out" || fail "the second holder was not told why: $out"
TFSTATE_LOCK_PID=$held_pid TFSTATE_LOCK_IN=$held_in TFSTATE_LOCK_OUT=$held_out TFSTATE_LOCK_DIR=$held_dir
tfstate_lock_release
tfstate_lock_acquire >/dev/null || fail "the lock stayed taken after its release"
tfstate_lock_release
out=$(NAS_DOWN=1 tfstate_lock_acquire) && fail "the lock was taken from a nas that is down"
grep -qF "TF_STATE_OFFLINE=1" <<<"$out" || fail "a nas outage does not name the offline mode: $out"
echo "ok: the lock admits one holder, frees on release, and names the way out when the nas is down"

# -----------------------------------------------------------------------------
# SIMULATION: two deployers, failing pushes, nas outages
# -----------------------------------------------------------------------------
NAS=$T/sim/nas; mkdir -p "$NAS" "$T/sim/A" "$T/sim/B"
state L 1 '[]' > "$NAS/state"
stops=0; lost_by_human=0
for step in $(seq 1 "$SIM_STEPS"); do
  d=$([ $((RANDOM % 2)) = 0 ] && echo A || echo B)
  TFSTATE_LOCAL=$T/sim/$d/local.tfstate
  push_fails=$([ $((RANDOM % 100)) -lt "$PUSH_FAIL_PERCENT" ] && echo 1 || echo 0)
  nas_down=$([ $((RANDOM % 100)) -lt "$NAS_DOWN_PERCENT" ] && echo 1 || echo 0)
  before=$(jq -c .applies "$TFSTATE_LOCAL" 2>/dev/null || echo '[]')
  had_unpushed=0
  if [ -f "$TFSTATE_LOCAL" ] && [ "$(jq -c --slurpfile n "$NAS/state" '.applies - $n[0].applies' "$TFSTATE_LOCAL")" != '[]' ]; then had_unpushed=1; fi
  tfstate_lock_acquire >/dev/null || fail "step $step: the lock was not taken"
  if ! tfstate_pull > "$T/pull.log"; then
    grep -qF "both changed" "$T/pull.log" || fail "step $step: unexpected pull stop: $(cat "$T/pull.log")"
    # the human decides: this deployer's diverged applies are dropped on purpose, the nas wins
    stops=$((stops + 1)); lost_by_human=$((lost_by_human + $(jq --slurpfile n "$NAS/state" '.applies - $n[0].applies | length' "$TFSTATE_LOCAL")))
    rm -f "$TFSTATE_LOCAL" "$TFSTATE_LOCAL.synced"
    tfstate_lock_release
    continue
  fi
  # a pull never silently drops an unpushed apply
  if [ "$had_unpushed" = 1 ]; then
    [ "$(jq -c --argjson b "$before" '$b - .applies' "$TFSTATE_LOCAL")" = '[]' ] || fail "step $step: the pull dropped local applies"
  fi
  apply "$TFSTATE_LOCAL" "$d$step"
  PUSH_FAILS=$push_fails NAS_DOWN=$nas_down tfstate_push > "$T/push.log" || fail "step $step: push stopped: $(cat "$T/push.log")"
  tfstate_lock_release
done
# liveness: with the faults gone, both deployers converge on the nas
for d in A B; do
  TFSTATE_LOCAL=$T/sim/$d/local.tfstate
  if ! tfstate_pull > "$T/pull.log"; then rm -f "$TFSTATE_LOCAL" "$TFSTATE_LOCAL.synced"; tfstate_pull >/dev/null; fi
  tfstate_push >/dev/null || fail "final push of $d stopped"
done
for d in A B; do
  TFSTATE_LOCAL=$T/sim/$d/local.tfstate
  tfstate_pull >/dev/null
  cmp -s "$TFSTATE_LOCAL" "$NAS/state" || fail "deployer $d did not converge on the nas"
done
echo "ok: $SIM_STEPS simulated syncs: no apply lost silently, $stops divergence stop(s) handed to the human ($lost_by_human apply(s) dropped by that decision), both deployers converge"
echo "tfstate: $cases table cases, the lock and the simulation hold"
