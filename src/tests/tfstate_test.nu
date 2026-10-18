# sync.nu's terraform state handling (scripts/lib/tfstate.nu) on local files: the nas is a directory, the lock a flock
# on it. A table of pull and push situations, the lock, then a seeded simulation of two deployers with failing pushes
# and nas outages whose oracle is: no apply ever disappears without a stop that names the divergence.
#
# usage: nu tfstate_test.nu <seed>, beside ../scripts/lib/tfstate.nu

use ../scripts/lib/tfstate.nu *

# simulated sync runs; each draws a deployer and its faults from the seed
const SIM_STEPS = 300
# percent of pushes whose write fails, and of syncs during which the nas is down at push time
const PUSH_FAIL_PERCENT = 20
const NAS_DOWN_PERCENT = 10
# glibc's rand(): 31 bits; the low bits of a power-of-two lcg cycle short, so draws take the high ones
const LCG_MULTIPLIER = 1103515245
const LCG_INCREMENT = 12345
const LCG_MODULUS = 2147483648
const LCG_DRAW_SHIFT = 65536

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def lcg-next [state: int]: nothing -> int { ($LCG_MULTIPLIER * $state + $LCG_INCREMENT) mod $LCG_MODULUS }
def lcg-draw [state: int, count: int]: nothing -> int { ($state // $LCG_DRAW_SHIFT) mod $count }

def applies [file: path]: nothing -> list { open --raw $file | from json | get applies }

def nas-down []: nothing -> bool { ($env.NAS_DOWN? | default "0") == "1" }

# the transport on local files; env NAS and NAS_DOWN pick the nas
def transport []: nothing -> record {
    {
        read: {|out|
            if (nas-down) { return 1 }
            let state = $env.NAS | path join state
            if not ($state | path exists) { return 2 }
            cp $state $out
            0
        }
        write: {|file|
            if (nas-down) or ($env.PUSH_FAILS? | default "0") == "1" { return false }
            let state = $env.NAS | path join state
            # the oracle: a write never drops an apply the nas holds
            if ($state | path exists) {
                let dropped = applies $state | where $it not-in (applies $file)
                if ($dropped | is-not-empty) { fail $"a push dropped applies ($dropped | to json --raw) from the nas" }
            }
            cp $file $"($state).new"
            mv --force $"($state).new" $state
            true
        }
        # the remote command sync.nu sends to the nas, on a local lock file; the closure's input must reach the
        # command unread, so the outage is decided inside it
        lock: {|| ^sh -c '[ "${NAS_DOWN:-0}" = 1 ] || flock -n "$1" -c "echo locked; exec cat >/dev/null" || echo busy' sh ($env.NAS | path join lock) }
    }
}

def state [lineage: string, serial: int, applies: list]: nothing -> string {
    {lineage: $lineage, serial: $serial, applies: $applies} | to json --raw
}

# what terraform does to a state: serial up, one more apply in it
def apply [file: path, id: string]: nothing -> nothing {
    open --raw $file | from json | update serial { $in + 1 } | update applies { append $id } | to json --raw | save --force $file
}

def main [seed: int]: nothing -> nothing {
    print $"seed=($seed)"
    run-table
    run-lock
    run-simulation $seed
}

def run-table []: nothing -> nothing {
    let t = mktemp --directory
    let tr = transport
    mut cases = 0

    let S10 = state L 10 [a]
    let S11 = state L 11 [a b]
    let S11c = state L 11 [a c]
    let S12 = state L 12 [a b d]
    let S12c = state L 12 [a b e]

    # <nas state or ""> <local state or ""> <synced: nas|local|none|the state json both last agreed on>
    let setup = {|n: int, nas: string, local: string, synced: string|
        let dir = $t | path join $"case-($n)"
        mkdir ($dir | path join nas)
        let local_file = $dir | path join local.tfstate
        if $nas != "" { $nas | save ($dir | path join nas state) }
        if $local != "" { $local | save $local_file }
        match $synced {
            "nas" => { tfstate-synced-set $local_file ($dir | path join nas state) }
            "local" => { tfstate-synced-set $local_file $local_file }
            "none" => {}
            _ => { $synced | save --force ($t | path join agreed.json); tfstate-synced-set $local_file ($t | path join agreed.json) }
        }
        {nas: ($dir | path join nas), local: $local_file}
    }
    let ok = {|n: int, result: record| if not $result.ok { fail $"case ($n): refused: ($result.message)" } }
    let stopped = {|n: int, says: string, result: record|
        if $result.ok { fail $"case ($n): expected a stop: ($result.message)" }
        if not ($result.message | str contains $says) { fail $"case ($n): the stop does not say '($says)': ($result.message)" }
    }
    let local_is = {|n: int, c: record, want: list| if (applies $c.local) != $want { fail $"case ($n): local holds (applies $c.local | to json --raw), not ($want | to json --raw)" } }
    let nas_is = {|n: int, c: record, want: list| if (applies ($c.nas | path join state)) != $want { fail $"case ($n): nas holds (applies ($c.nas | path join state) | to json --raw), not ($want | to json --raw)" } }
    let pull = {|c: record| with-env {NAS: $c.nas} { tfstate-pull $tr $c.local } }
    let push = {|c: record| with-env {NAS: $c.nas} { tfstate-push $tr $c.local } }

    $cases += 1; let c = do $setup $cases "" "" none
    do $stopped $cases "First deploy of an empty lab" (do $pull $c); print "ok: no state anywhere stops"

    $cases += 1; let c = do $setup $cases "" $S10 local
    tfstate-set-aside $c.local | ignore
    if ($c.local | path exists) or ($"($c.local).synced" | path exists) { fail "set aside left the working copy in place" }
    let aside = glob $"($c.local).*.backup"
    if ($aside | length) != 1 or (applies $aside.0) != [a] or not ($"($aside.0).synced" | path exists) { fail "set aside lost the copy or its agreement" }
    tfstate-set-aside $c.local | ignore
    if (glob $"($c.local).*.backup") != $aside { fail "a second set aside touched the first" }
    do $stopped $cases "First deploy of an empty lab" (do $pull $c)
    print "ok: a fresh start sets the copy aside whole, keeps it, and then finds no state"

    $cases += 1; let c = do $setup $cases "" $S10 none
    do $ok $cases (do $pull $c); do $local_is $cases $c [a]; print "ok: no nas state keeps the local copy"
    $cases += 1; let c = do $setup $cases $S10 "" none
    do $ok $cases (do $pull $c); do $local_is $cases $c [a]; print "ok: a missing local copy takes the nas"
    $cases += 1; let c = do $setup $cases $S10 $S10 none
    do $ok $cases (do $pull $c)
    if (tfstate-synced-get $c.local) != (tfstate-hash ($c.nas | path join state)) { fail "an equal copy did not record the agreement" }
    print "ok: equal copies agree"
    $cases += 1; let c = do $setup $cases $S10 $S11 nas
    do $ok $cases (do $pull $c); do $local_is $cases $c [a b]; print "ok: an unpushed local apply is kept"
    $cases += 1; let c = do $setup $cases $S11 $S10 local
    do $ok $cases (do $pull $c); do $local_is $cases $c [a b]; print "ok: a newer nas replaces an unchanged local copy"
    $cases += 1; let c = do $setup $cases $S11c $S11 none
    do $stopped $cases "both changed" (do $pull $c); print "ok: same serial, other content, stops"
    $cases += 1; let c = do $setup $cases $S11c $S12 none
    do $stopped $cases "both changed" (do $pull $c); print "ok: no agreement and the local copy ahead stops"
    $cases += 1; let c = do $setup $cases $S12c $S12 $S11
    do $stopped $cases "both changed" (do $pull $c); do $local_is $cases $c [a b d]
    print "ok: both moved on from the last agreement stops (the serial-only rule pushed over this)"
    $cases += 1; let c = do $setup $cases (state M 10 [a]) $S10 nas
    do $stopped $cases "lineage differs" (do $pull $c); print "ok: another lineage stops"
    $cases += 1; let c = do $setup $cases $S10 $S10 nas
    do $stopped $cases "does not answer" (with-env {NAS_DOWN: "1"} { do $pull $c }); print "ok: an unreachable nas stops the pull"

    $cases += 1; let c = do $setup $cases $S10 $S11 nas
    do $ok $cases (do $push $c); do $nas_is $cases $c [a b]; print "ok: a newer local serial is pushed"
    $cases += 1; let c = do $setup $cases $S10 $S10 nas
    do $ok $cases (do $push $c); do $nas_is $cases $c [a]; print "ok: nothing new, nothing pushed"
    $cases += 1; let c = do $setup $cases $S11c $S12 $S11
    do $stopped $cases "not the one this run started from" (do $push $c); do $nas_is $cases $c [a c]
    print "ok: a nas changed under the run is not overwritten"
    $cases += 1; let c = do $setup $cases "" $S10 none
    do $ok $cases (do $push $c); do $nas_is $cases $c [a]; print "ok: the first push creates the nas state"
    $cases += 1; let c = do $setup $cases $S10 $S11 nas
    let out = with-env {NAS_DOWN: "1"} { do $push $c }
    if not ($out.message | str contains "the next sync pushes it") { fail $"nas down at push: ($out.message)" }
    do $nas_is $cases $c [a]; do $ok $cases (do $pull $c); do $local_is $cases $c [a b]; do $ok $cases (do $push $c); do $nas_is $cases $c [a b]
    print "ok: a push the nas missed stays ahead and goes up next run"
    print $"tfstate: ($cases) table cases hold"
}

def run-lock []: nothing -> nothing {
    let nas = mktemp --directory
    let tr = transport
    with-env {NAS: $nas} {
        let held = tfstate-lock-acquire $tr
        if not $held.ok { fail $"the free lock was not taken: ($held.message)" }
        let second = tfstate-lock-acquire $tr
        if $second.ok { fail "a second holder got the lock" }
        if not ($second.message | str contains "another sync holds") { fail $"the second holder was not told why: ($second.message)" }
        tfstate-lock-release $held
        let again = tfstate-lock-acquire $tr
        if not $again.ok { fail $"the lock stayed taken after its release: ($again.message)" }
        tfstate-lock-release $again
        let down = with-env {NAS_DOWN: "1"} { tfstate-lock-acquire $tr }
        if $down.ok { fail "the lock was taken from a nas that is down" }
        if not ($down.message | str contains "TF_STATE_OFFLINE=1") { fail $"a nas outage does not name the offline mode: ($down.message)" }
    }
    print "ok: the lock admits one holder, frees on release, and names the way out when the nas is down"
}

def run-simulation [seed: int]: nothing -> nothing {
    let t = mktemp --directory
    let nas = $t | path join nas
    mkdir $nas ($t | path join A) ($t | path join B)
    state L 1 [] | save ($nas | path join state)
    let tr = transport
    mut rng = $seed mod $LCG_MODULUS
    mut stops = 0
    mut lost_by_human = 0
    for step in 1..$SIM_STEPS {
        $rng = lcg-next $rng
        let d = if (lcg-draw $rng 2) == 0 { "A" } else { "B" }
        $rng = lcg-next $rng
        let push_fails = if (lcg-draw $rng 100) < $PUSH_FAIL_PERCENT { "1" } else { "0" }
        $rng = lcg-next $rng
        let nas_down = if (lcg-draw $rng 100) < $NAS_DOWN_PERCENT { "1" } else { "0" }
        let local = $t | path join $d local.tfstate
        let before = if ($local | path exists) { applies $local } else { [] }
        let nas_applies = applies ($nas | path join state)
        let had_unpushed = ($before | where $it not-in $nas_applies | is-not-empty)
        let lock = with-env {NAS: $nas} { tfstate-lock-acquire $tr }
        if not $lock.ok { fail $"step ($step): the lock was not taken: ($lock.message)" }
        let pulled = with-env {NAS: $nas} { tfstate-pull $tr $local }
        if not $pulled.ok {
            if not ($pulled.message | str contains "both changed") { fail $"step ($step): unexpected pull stop: ($pulled.message)" }
            # the human decides: this deployer's diverged applies are dropped on purpose, the nas wins
            $stops += 1
            $lost_by_human += (applies $local | where $it not-in (applies ($nas | path join state)) | length)
            rm --force $local $"($local).synced"
            tfstate-lock-release $lock
            continue
        }
        # a pull never silently drops an unpushed apply
        if $had_unpushed and ($before | where $it not-in (applies $local) | is-not-empty) { fail $"step ($step): the pull dropped local applies" }
        apply $local $"($d)($step)"
        let pushed = with-env {NAS: $nas, PUSH_FAILS: $push_fails, NAS_DOWN: $nas_down} { tfstate-push $tr $local }
        if not $pushed.ok { fail $"step ($step): push stopped: ($pushed.message)" }
        tfstate-lock-release $lock
    }
    # liveness: with the faults gone, both deployers converge on the nas
    with-env {NAS: $nas} {
        for d in [A B] {
            let local = $t | path join $d local.tfstate
            if not (tfstate-pull $tr $local).ok {
                rm --force $local $"($local).synced"
                tfstate-pull $tr $local | ignore
            }
            if not (tfstate-push $tr $local).ok { fail $"final push of ($d) stopped" }
        }
        for d in [A B] {
            let local = $t | path join $d local.tfstate
            tfstate-pull $tr $local | ignore
            if (open --raw $local) != (open --raw ($nas | path join state)) { fail $"deployer ($d) did not converge on the nas" }
        }
    }
    print $"ok: ($SIM_STEPS) simulated syncs: no apply lost silently, ($stops) divergence stop\(s\) handed to the human \(($lost_by_human) apply\(s\) dropped by that decision\), both deployers converge"
}
