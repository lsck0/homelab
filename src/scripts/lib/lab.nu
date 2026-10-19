# reaching and deploying the lab's guests for sync.nu: ssh through the generated config, the Proxmox api, host keys
# read through the hypervisor, and one guest's deploy
#
# `lab` is the record sync.nu builds once: {src, inventory, known_hosts, ssh_config, proxmox: {ssh, user, host, port},
# api: {url, node, ca, auth}}.

use tools.nu [sh-quote warn]

const HOST_KEY_PATH = "/etc/ssh/ssh_host_ed25519_key.pub"
# a guest booting or rebooting: up to 5 minutes for its sshd, and 3 for its qemu agent or container to answer
const SSH_WAIT_ATTEMPTS = 60
const SSH_WAIT_INTERVAL = 5sec
const HOST_KEY_ATTEMPTS = 36
const HOST_KEY_RETRY = 5sec
# one ssh call that must not hang the run; a probe in a retry loop gives up sooner
export const SSH_CONNECT_TIMEOUT_S = 5
const SSH_PROBE_TIMEOUT_S = 3
# a switch still running after this hangs (a hard nfs mount, a unit that never settles): the deploy fails and the run
# goes on to release the state lock and the reaper; half an hour leaves room for the image pulls a switch waits on
const SWITCH_TIMEOUT_S = 1800
# a closure copy over the lan, gigabytes at worst; a stalled one fails its deploy instead of holding the run
const COPY_TIMEOUT_S = 1800
# a terraform disk bump grows the disk but not the partition: more unpartitioned space than this reboots the guest so
# boot.growPartition takes it; 64 MiB is above the alignment slack every partitioning leaves
const GROW_REBOOT_SLACK_BYTES = 67108864
const BYTES_PER_GIB = 1073741824
const HOST_AGE_KEY_PATH = "/var/lib/sops-nix/key.txt"
const NIX_FEATURES = [--extra-experimental-features "nix-command flakes"]
# the switch's own status, as the last line of its output: a timeout or a lost connection leaves none
const SWITCH_STATUS_MARK = "homelab-switch-status="
# the toplevel sync.nu last deployed, for the guest to tell from the one it runs (drift: a hand switch, a rollback)
const DEPLOYED_TOPLEVEL_FILE = "/var/lib/homelab/deployed-toplevel"
const KNOWN_HOSTS_HEADER = [
    "# every ssh host key of the lab, checked strictly by sync.nu, hermes and the owner's ssh config"
    "# Proxmox: pinned by src/scripts/init.nu --pin after a console check. Guests: written by sync.nu from each"
    "# guest's own /etc/ssh/ssh_host_ed25519_key.pub, read through the Proxmox host (qemu agent, pct pull)"
]
# on proxmox: "<id> lxc <key line>" (pct pull) or "<id> vm <agent json>" per guest; the final true ignores a silent
# last guest
const HOST_KEYS_REMOTE = r#'for g in "${@:2}"; do
  id=${g%:*}
  if [ "${g#*:}" = lxc ]; then
    # pull, not exec: a nixos container has no cat on pct's PATH
    t=$(mktemp) && pct pull "$id" "$1" "$t" 2>/dev/null && printf '%s lxc %s\n' "$id" "$(cat "$t")"
    rm -f "$t"
  else
    out=$(qm guest exec "$id" --timeout 10 -- cat "$1" 2>/dev/null) && printf '%s vm %s\n' "$id" "$(echo "$out" | tr -d '\n')"
  fi
done
true'#
const ED25519_KEY = '^[A-Za-z0-9+/]+=*$'

# the command's {exit_code, stdout, stderr} on a guest, never raising
export def lab-ssh-try [lab: record, ip: string, command: string, --timeout-s: int = 5]: any -> record {
    $in | do { ^ssh -F $lab.ssh_config -o $"ConnectTimeout=($timeout_s)" $"root@($ip)" $command } | complete
}

export def --wrapped proxmox-ssh [lab: record, ...args: string]: any -> any {
    let ssh = $lab.proxmox.ssh
    $in | ^$ssh.0 ...($ssh | skip 1) $"($lab.proxmox.user)@($lab.proxmox.host)" ...$args
}

export def wait-for-ssh [lab: record, ip: string, attempts: int = $SSH_WAIT_ATTEMPTS]: nothing -> bool {
    for _ in 1..$attempts {
        if (lab-ssh-try $lab $ip "true" --timeout-s $SSH_PROBE_TIMEOUT_S).exit_code == 0 { return true }
        sleep $SSH_WAIT_INTERVAL
    }
    print $"ERROR: SSH not reachable at ($ip)"
    false
}

# the proxmox api's guest type: containers live under /lxc, vms under /qemu
def api-kind [lab: record, id: string]: nothing -> string {
    if ($lab.inventory | get $id | get kind) == "lxc" { "lxc" } else { "qemu" }
}

def --wrapped api [lab: record, ...args: string]: nothing -> record {
    do { ^curl -sf --cacert $lab.api.ca -H $"@($lab.api.auth)" ...$args } | complete
}

export def guest-status [lab: record, id: string]: nothing -> string {
    let got = api $lab $"($lab.api.url)/nodes/($lab.api.node)/(api-kind $lab $id)/($id)/status/current"
    if $got.exit_code != 0 { return "unknown" }
    try { $got.stdout | from json | get data.status } catch { "unknown" }
}

# start the guest unless it runs; a start that fails surfaces as its deploy's ssh wait timing out
export def guest-wake [lab: record, id: string]: nothing -> nothing {
    let status = guest-status $lab $id
    if $status == "running" { return }
    print $">>>   starting vm-($id) \(($status)\)"
    api $lab -X POST $"($lab.api.url)/nodes/($lab.api.node)/(api-kind $lab $id)/($id)/status/start" | ignore
}

# a clean shutdown, for a scale-to-zero guest the run woke only for its deploy
export def guest-sleep [lab: record, id: string]: nothing -> nothing {
    print $">>>   stopping vm-($id) again, it scales to zero"
    api $lab -X POST $"($lab.api.url)/nodes/($lab.api.node)/(api-kind $lab $id)/($id)/status/shutdown" | ignore
}

# {<id>: "<key type> <key>"} of every guest whose ed25519 host key the hypervisor could read from inside it; a guest
# still booting is left out
def host-keys-read [lab: record, ids: list<string>]: nothing -> record {
    let guests = $ids | each {|id| $"($id):(if ($lab.inventory | get $id | get kind) == 'lxc' { 'lxc' } else { 'vm' })" }
    let replies = $HOST_KEYS_REMOTE | do { proxmox-ssh $lab $"bash -s -- ($HOST_KEY_PATH) ($guests | str join ' ')" } | complete | get stdout | lines
    $replies | each {|reply|
        let parts = $reply | split row --number 3 " "
        if ($parts | length) < 3 { return null }
        # a reply that is no json, or no key line, is filtered out below
        let line = if $parts.1 == "vm" { try { $parts.2 | from json | get out-data } catch { "" } } else { $parts.2 }
        let key = $line | str trim | split row " "
        if ($key | length) >= 2 and $key.0 == "ssh-ed25519" and $key.1 =~ $ED25519_KEY { {id: $parts.0, key: $"($key.0) ($key.1)"} }
    } | compact | reduce --fold {} {|e, acc| $acc | upsert $e.id $e.key }
}

# rewrites the guests' lines of src/generated/known_hosts from the hypervisor's view; a guest it cannot read keeps its
# previous line, and fails its deploy if it has none
export def host-keys-learn [lab: record, ids: list<string>]: nothing -> nothing {
    mut learned = {}
    for attempt in 1..$HOST_KEY_ATTEMPTS {
        let known = $learned | columns
        $learned = $learned | merge (host-keys-read $lab ($ids | where $it not-in $known))
        let known = $learned | columns
        if ($ids | all { $in in $known }) { break }
        if $attempt != $HOST_KEY_ATTEMPTS { sleep $HOST_KEY_RETRY }
    }
    let learned = $learned
    let missing = $ids | where $it not-in ($learned | columns)
    if ($missing | is-not-empty) {
        warn $"no host key from the hypervisor for ($missing | each { $'vm-($in)' } | str join ' ') \(agent or container not answering\)"
    }
    let current = open --raw $lab.known_hosts | lines | where { not ($in | str starts-with "#") and $in != "" }
        | each { split row " " } | where { ($in | length) >= 3 }
    let pinned = [$lab.proxmox.host $"[($lab.proxmox.host)]:($lab.proxmox.port)"]
    let proxmox_lines = $current | where { $in.0 in $pinned } | each { str join " " }
    let guest_lines = $lab.inventory | items {|id, guest|
        let old = $current | where { $in.0 == $guest.ip } | get --optional 0 | default [] | skip 1 | first 2 | str join " "
        let new = $learned | get --optional $id
        if $new != null {
            if $old != "" and $old != $new { print -e $">>> vm-($id): new host key \(the guest was recreated\)" }
            $"($guest.ip) ($new)"
        } else if $old != "" {
            $"($guest.ip) ($old)"
        }
    } | compact
    let tmp = mktemp --tmpdir-path ($lab.known_hosts | path dirname) .known_hosts.XXXXXX
    $KNOWN_HOSTS_HEADER ++ $proxmox_lines ++ $guest_lines | each { $"($in)\n" } | str join | save --force $tmp
    ^chmod 644 $tmp
    mv --force $tmp $lab.known_hosts
}

# scripts/lib/<script> under the nu of the closure being deployed (modules/base), its input on stdin: a guest still on
# a generation without nu runs it too. ssh joins argv into one remote command
def guest-payload [lab: record, ip: string, toplevel: string, script: string, ...args: string]: any -> record {
    let source = open --raw ($lab.src | path join scripts lib $script)
    let call = ["\n$in | main" ...($args | each { to nuon })] | str join " "
    let program = $source + $call
    let guest_nu = $toplevel | path join sw bin nu
    $in | lab-ssh-try $lab $ip $"(sh-quote $guest_nu) --no-config-file --stdin -c (sh-quote $program)"
}

# scripts/lib/host-age-key.nu on the guest with its own key: "changed", "" or null when it failed
def host-age-key-run [lab: record, toplevel: string, action: string, key: string, ip: string]: nothing -> any {
    let run = $"($key)\n" | guest-payload $lab $ip $toplevel host-age-key.nu $action $HOST_AGE_KEY_PATH
    if $run.exit_code != 0 {
        print $"ERROR: the age key did not reach ($ip): ($run.stderr | str trim)"
        return null
    }
    $run.stdout | str trim
}

# the guest answers again, with another boot id
def wait-for-reboot [lab: record, ip: string, boot_id: string]: nothing -> bool {
    for _ in 1..$SSH_WAIT_ATTEMPTS {
        let now = lab-ssh-try $lab $ip "cat /proc/sys/kernel/random/boot_id" --timeout-s $SSH_PROBE_TIMEOUT_S
        if $now.exit_code == 0 and ($now.stdout | str trim) != $boot_id { return true }
        sleep $SSH_WAIT_INTERVAL
    }
    false
}

def deployed-toplevel-record [lab: record, name: string, ip: string, toplevel: string]: nothing -> bool {
    let dir = $DEPLOYED_TOPLEVEL_FILE | path dirname
    let recorded = lab-ssh-try $lab $ip $"mkdir -p ($dir) && echo ($toplevel) > ($DEPLOYED_TOPLEVEL_FILE)"
    if $recorded.exit_code != 0 { print $"ERROR: ($name): the deployed toplevel is not recorded: ($recorded.stderr | str trim)" }
    $recorded.exit_code == 0
}

# the router deploys before the batch build finishes and builds its own (toplevel null); a host the batch failed has ""
export def deploy-nixos [lab: record, name: string, ip: string, toplevel: any, host_key: string]: nothing -> bool {
    print $">>> Deploying ($name) to ($ip)..."
    if (do { ^ssh-keygen -F $ip -f $lab.known_hosts } | complete).exit_code != 0 {
        print $"ERROR: no host key for ($name) \(($ip)\) in src/generated/known_hosts: the hypervisor could not read it"
        return false
    }
    if not (wait-for-ssh $lab $ip) { return false }

    let toplevel = if $toplevel != null { $toplevel } else {
        do { ^nix build $"($lab.src)#nixosConfigurations.($name).config.system.build.toplevel" ...$NIX_FEATURES --no-link --print-out-paths } | complete
            | get stdout | lines | last 1 | get --optional 0 | default ""
    }
    if $toplevel == "" or not ($toplevel | path exists) {
        print $"ERROR: Build failed for ($name)"
        return false
    }

    # first, so the key's payload runs under the closure's nu; a copy the guest holds already only checks the paths.
    # Closures are local builds, no sigs
    let copied = do { ^timeout $COPY_TIMEOUT_S nix copy ...$NIX_FEATURES --no-check-sigs --to $"ssh-ng://root@($ip)" $toplevel } | complete
    if $copied.exit_code != 0 {
        print $"ERROR: ($name): the closure did not copy: ($copied.stderr | str trim | lines | last 3 | str join ' ')"
        return false
    }

    # before the up-to-date check: a lost or stale key on an unchanged host is repaired, then re-activated
    let key_state = host-age-key-run $lab $toplevel push $host_key $ip
    if $key_state == null { return false }
    # unreadable means deploy anyway
    let current = lab-ssh-try $lab $ip "readlink -f /run/current-system" | get stdout | str trim
    if $current == $toplevel and $key_state != "changed" {
        print $">>> ($name) already up-to-date. Skipping."
        return (deployed-toplevel-record $lab $name $ip $toplevel)
    }
    if $key_state == "changed" { print $">>> ($name): age key replaced, re-activating to decrypt its secrets" }

    # switch in place, no reboot; its lines show live, prefixed with the guest
    let switch = $"nix-env -p /nix/var/nix/profiles/system --set '($toplevel)' && '($toplevel)/bin/switch-to-configuration' switch; echo ($SWITCH_STATUS_MARK)$?"
    let output = ^timeout $SWITCH_TIMEOUT_S ssh -F $lab.ssh_config $"root@($ip)" $switch o+e>| lines | each {|line|
        if not ($line | str starts-with $SWITCH_STATUS_MARK) { print $"($name) | ($line)" }
        $line
    }
    let status = $output | where { str starts-with $SWITCH_STATUS_MARK } | get --optional 0 | default "" | str replace $SWITCH_STATUS_MARK ""
    if $status == "" {
        print $"ERROR: ($name): the switch did not finish within ($SWITCH_TIMEOUT_S)s, or the connection dropped."
        return false
    }
    if $status != "0" {
        let printed = $output | where { not ($in | str starts-with $SWITCH_STATUS_MARK) } | str join "\n"
        let judged = $printed | guest-payload $lab $ip $toplevel switch-failures.nu
        let failed = if $judged.exit_code == 0 { $judged.stdout | str trim | lines | str join " " } else { "unknown: the guest did not answer" }
        if $failed != "" {
            print $"ERROR: ($name): the switch failed \(exit ($status)\): ($failed)"
            return false
        }
        print $">>> ($name): only transient units failed during the switch."
    }
    if $key_state == "changed" and (host-age-key-run $lab $toplevel settle $host_key $ip) == null { return false }
    if not (deployed-toplevel-record $lab $name $ip $toplevel) { return false }
    print $">>> ($name) deployed."

    # a terraform disk bump grows the disk, not the partition; an lxc has no /dev/sda, reads 0
    let sizes = lab-ssh-try $lab $ip "echo $(lsblk -bdno SIZE /dev/sda 2>/dev/null || echo 0) $(lsblk -bdno SIZE /dev/sda1 2>/dev/null || echo 0) $(cat /proc/sys/kernel/random/boot_id)"
    let fields = if $sizes.exit_code == 0 { $sizes.stdout | str trim | split row " " } else { ["0" "0" "-"] }
    let disk = try { $fields.0 | into int } catch { 0 }
    let part = try { $fields.1 | into int } catch { 0 }
    if $disk > 0 and $part > 0 and ($disk - $part) > $GROW_REBOOT_SLACK_BYTES {
        print $">>> ($name): disk grew to ($disk // $BYTES_PER_GIB)G, rebooting to expand the partition"
        # the reboot drops the connection, which ssh reports as a failure
        lab-ssh-try $lab $ip "systemctl reboot" | ignore
        if not (wait-for-reboot $lab $ip ($fields | get --optional 2 | default "-")) { warn $"($name) did not return after the grow reboot" }
    }
    true
}
