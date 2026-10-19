#!/usr/bin/env -S nu --no-config-file
# sync.nu's own decisions, from this machine alone: which guests a run names, the deploy plan it orders them in, and
# its read-back of the Proxmox anti-spoofing rules against stubbed systemctl and nft. No network.
#
# usage: nu sync_plan_test.nu <repo>, the repo whose top holds sync.nu

const INVENTORY = {
    "300": {name: "luca-router", type: router, powered: true, idle: null}
    "104": {name: "104-internal-nas", type: internal, powered: true, idle: null}
    "107": {name: "107-internal-swarm", type: internal, powered: true, idle: null}
    "112": {name: "112-internal-archbuild", type: internal, powered: true, idle: {stopAfter: 30min}}
    "130": {name: "130-internal-homeassistant", type: internal, powered: false, idle: null}
}
const NAS_ID = "104"
# proxmox-firewall's guest chains as `nft list table` prints them: 100 drops spoofed sources, 101 has ipfilter alone
const CHAINS = '
table bridge proxmox-firewall-guests {
	chain guest-100-out {
		iifname "tap100i0" ip saddr != @v4-guest-100/ipfilter-net0 ip saddr @v4-guest-100/ipfilter-net0-nomatch drop
		ip saddr @v4-guest-100/spoofed ip saddr != @v4-guest-100/spoofed-nomatch drop
	}
	chain guest-101-out {
		iifname "tap101i0" ip saddr != @v4-guest-101/ipfilter-net0 ip saddr @v4-guest-101/ipfilter-net0-nomatch drop
	}
}
'

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

# <code> after sync.nu's definitions, in a nu of its own: {exit_code, stdout, stderr}
def sync-run-code [repo: path, code: string]: nothing -> record {
    let source = $"source ($repo | path join sync.nu | to nuon)\nlet inventory = ($INVENTORY | to nuon)\n($code)"
    do { ^$nu.current-exe --no-config-file -c $source } | complete
}

def sync-eval [repo: path, code: string]: nothing -> any {
    let ran = sync-run-code $repo $"($code) | to nuon"
    if $ran.exit_code != 0 { fail $"`($code)` failed: ($ran.stderr)" }
    $ran.stdout | from nuon
}

def main [repo: path]: nothing -> nothing {
    let repo = $repo | path expand

    let named = {|names: list<string>| sync-eval $repo $"guests-select $inventory ($names | to nuon)" }
    if (do $named [] | sort) != ($INVENTORY | columns | sort) { fail "no names: not every guest" }
    if (do $named ["104-internal-nas" "112"]) != ["104" "112"] { fail "a name and a vmid: other guests" }
    if (do $named ["300-router"]) != ["300"] { fail "the router's folder name does not name it" }
    if (do $named ["luca-router"]) != ["300"] { fail "the router's own name does not name it" }
    let unknown = sync-run-code $repo "guests-select $inventory [nas]"
    if $unknown.exit_code == 0 or not ($unknown.stderr | str contains "no guest named nas") { fail $"an unknown name passed: ($unknown.stderr)" }

    let plan = {|names: list<string>|
        sync-eval $repo $"deploy-plan $inventory ($NAS_ID | to nuon) \(guests-select $inventory ($names | to nuon)\) | reject guests"
    }
    let full = do $plan []
    if not $full.router { fail "a full run: the router is not deployed" }
    if $full.nas.id != $NAS_ID { fail "a full run: the nas is not deployed alone" }
    if ($full.parallel | get id) != ["107"] { fail $"a full run: in parallel ($full.parallel | get id)" }
    if ($full.idle | get id) != ["112"] { fail $"a full run: scale-to-zero ($full.idle | get id)" }
    if $full.unpowered != ["130"] { fail $"a full run: powered off ($full.unpowered)" }
    let one = do $plan ["107"]
    if $one.router or $one.nas != null or ($one.parallel | get id) != ["107"] or ($one.idle | is-not-empty) {
        fail $"one guest named: other guests deployed: ($one)"
    }

    let stubs = mktemp --directory --tmpdir
    let chains = $stubs | path join chains
    $CHAINS | save $chains
    'echo "$CHECK_SYSTEMCTL"; exit "$CHECK_ACTIVE"' | save ($stubs | path join systemctl)
    $"cat ($chains)" | save ($stubs | path join nft)
    ^chmod +x ($stubs | path join systemctl) ($stubs | path join nft)
    let check = {|ids: list<string>, active: string|
        let script = sync-eval $repo "$FIREWALL_CHECK_REMOTE"
        with-env {PATH: ($env.PATH | prepend $stubs), CHECK_ACTIVE: $active, CHECK_SYSTEMCTL: ""} {
            $"($ids | str join "\n")\n" | do { ^sh -c $script } | complete
        }
    }
    if (do $check ["100"] "0").exit_code != 0 { fail "a guest whose spoofed drop is loaded failed the check" }
    let unguarded = do $check ["100" "101" "10"] "0"
    if $unguarded.exit_code == 0 { fail "guests without a spoofed drop passed the check" }
    if not ($unguarded.stdout | str contains "for: 101 10 ") { fail $"the check does not name the unguarded guests: ($unguarded.stdout)" }
    let stopped = do $check ["100"] "3"
    if $stopped.exit_code == 0 or not ($stopped.stdout | str contains "not running") { fail "a stopped proxmox-firewall passed the check" }
    rm --recursive --force $stubs
    print "sync-plan: all cases pass"
}
