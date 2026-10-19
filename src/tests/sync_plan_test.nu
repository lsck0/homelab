#!/usr/bin/env -S nu --no-config-file
# sync.nu's own decisions, from this machine alone: which guests a run names, the deploy plan it orders them in, its
# read-back of the Proxmox anti-spoofing rules against stubbed systemctl and nft, and how a deploy judges a switch
# against a stubbed ssh. No network.
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

# a guest for deploy-nixos: answers by the remote command, a switch with the next of $SWITCH_STATUSES, the failure
# judge with $JUDGED_FAILED after keeping the output it judges
const GUEST_SSH = '#!/bin/sh
for command; do :; done
case $command in
*"the following units failed"*) cat > "$STUBS/judged"; printf "%s" "$JUDGED_FAILED" ;;
*--stdin*) cat > /dev/null ;;
*switch-to-configuration*)
  count=$(( $(cat "$STUBS/switches" 2>/dev/null || echo 0) + 1 ))
  echo $count > "$STUBS/switches"
  echo "switch run $count"
  echo "homelab-switch-status=$(echo $SWITCH_STATUSES | cut -d " " -f $count)" ;;
*readlink*) echo /nix/store/old-system ;;
*deploy-pending*) echo "$command" >> "$STUBS/pending" ;;
*lsblk*) echo "0 0 boot" ;;
esac
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

    # {exit_code, stdout, switches, judged}: one deploy of a guest whose switches exit with <statuses> in turn
    let deploy = {|statuses: string, judged_failed: string|
        let stubs = mktemp --directory --tmpdir
        $GUEST_SSH | save ($stubs | path join ssh)
        "#!/bin/sh\n" | save ($stubs | path join ssh-keygen)
        "#!/bin/sh\n" | save ($stubs | path join nix)
        ^chmod +x ($stubs | path join ssh) ($stubs | path join ssh-keygen) ($stubs | path join nix)
        let lab = {src: ($repo | path join src), ssh_config: "/dev/null", known_hosts: "/dev/null"}
        let code = $"if not \(deploy-nixos ($lab | to nuon) guest 10.0.0.1 ($stubs | to nuon) key\) { exit 3 }"
        let env_stubbed = {PATH: ($env.PATH | prepend $stubs), STUBS: $stubs, SWITCH_STATUSES: $statuses, JUDGED_FAILED: $judged_failed}
        let ran = with-env $env_stubbed { sync-run-code $repo $code }
        let judged = $stubs | path join judged
        let outcome = {
            exit_code: $ran.exit_code
            stdout: $ran.stdout
            switches: (open --raw ($stubs | path join switches) | str trim | into int)
            judged: (if ($judged | path exists) { open --raw $judged } else { null })
        }
        rm --recursive --force $stubs
        $outcome
    }
    let retried = do $deploy "4 0" ""
    if $retried.exit_code != 0 { fail $"units failed, then a clean switch: the deploy failed: ($retried.stdout)" }
    if $retried.switches != 2 { fail $"units failed: ($retried.switches) switches, not one more" }
    if $retried.judged != null { fail "units failed, then a clean switch: the first switch was judged" }
    let failed_twice = do $deploy "4 4" "podman-homepage.service"
    if $failed_twice.exit_code == 0 { fail "units failed in both switches: the deploy passed" }
    if $failed_twice.switches != 2 { fail $"units failed in both switches: ($failed_twice.switches) switches, not 2" }
    if ($failed_twice.judged | str contains "switch run 1") or not ($failed_twice.judged | str contains "switch run 2") {
        fail $"units failed in both switches: not the second switch judged: ($failed_twice.judged)"
    }
    if (do $deploy "0" "").switches != 1 { fail "a clean switch: switched again" }
    if (do $deploy "1 0" "").switches != 1 { fail "a switch failing otherwise than by its units: switched again" }

    let stubs = mktemp --directory --tmpdir
    $GUEST_SSH | save ($stubs | path join ssh)
    ^chmod +x ($stubs | path join ssh)
    let lab = {ssh_config: "/dev/null"} | to nuon
    let code = $"deploy-pending-add ($lab) [10.0.0.1 10.0.0.2]; deploy-pending-remove ($lab) [10.0.0.1]"
    let ran = with-env {PATH: ($env.PATH | prepend $stubs), STUBS: $stubs} { sync-run-code $repo $code }
    if $ran.exit_code != 0 { fail $"the deploy-pending mark failed: ($ran.stderr)" }
    let pending = open --raw ($stubs | path join pending) | lines
    if ($pending | where { str contains "touch" } | length) != 2 { fail $"not both guests marked: ($pending)" }
    if not ($pending | last | str contains "rm -f") { fail $"the mark is not removed after its guests are marked: ($pending)" }
    rm --recursive --force $stubs
    print "sync-plan: all cases pass"
}
