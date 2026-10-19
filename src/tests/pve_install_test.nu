#!/usr/bin/env -S nu --no-config-file
# scripts/pve-install.nu's own decisions, with the Proxmox and Debian tools stubbed: the lldap realm fails closed
# without the guest's certificate and binds over ldaps with it; pvestatd's lvm config is written whole, read back by
# lvm's own parser and installed only when it rejects every name of the bulk pv; openipmi is masked only on a host
# without a bmc; the node's name moves to its lan address only on a standalone host that holds it, and the api
# certificate is re-signed only when it does not name that address; the recovery settings reboot a hung host and a
# softdog fed in place of the hardware watchdog is reported; root's ssh takes keys alone, never through a config sshd
# refuses or ignores; the lab's subnets route through the router; the firewall runs on nftables; the journal uploads
# to vm-103; the textfiles count each drive's thermal time and this boot's machine checks, and name smartd's warning
# by its first line; an upgrade keeps the host's config files and names the kernel a reboot would start; an
# unavailable package mirror or github leaves the host exporter and OSSEC for the next run instead of stopping the
# converge.
#
# Each case runs the script's functions in a nu of its own, so its exit and stderr are the converge's. The stubs are
# nu scripts first on PATH; they log every call to $CALLS and answer by the env the case sets:
#   GUEST          vm, lxc or down: how the lldap guest answers
#   ACL            1 when the realm's group already administers /
#   MIRROR GITHUB  up or down
#   WATCHDOG       up, or down when the chipset's watchdog does not load
#   FW_OPTIONS     the node's firewall options as pvesh prints them
#   SSHD_VALID     1 when sshd -t accepts the config; SSHD_READS 1 when sshd -T shows the drop-in's settings
#   KERNEL         what uname -r prints
#   MCE_LINES      how many hardware error lines the kernel logged this boot
#   IPMI_STATE     what is-enabled prints for openipmi; IPMI_FAILED 1 when it failed
#   LVM_PVE        1 when the pve group is seen; LVM_FILTERS 1 when lvm applies the config's filter
#   LOCAL_IP       what the interfaces hold
# The certificate's address is state pvecm changes, so it lives in a file.
#
# usage: pve_install_test.nu <scripts/pve-install.nu>

const NODE = "luca-server"
const PROXMOX_IP = "192.168.178.200"
const INSTALLER_IP = "192.168.178.2"
const ROUTER_IP = "192.168.178.29"
const CERT = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
# pve-install.nu's TEXTFILE_DIR
const TEXTFILE_DIR_HOST = "/var/lib/prometheus/node-exporter"

# name -> body of main [...args]; every stub logs its call first
const STUBS = {
    qm: '
        match [($args | get 0) $env.GUEST] {
            [status vm] => { exit 0 }
            [status _] => { exit 2 }
            [guest vm] => { print ({exitcode: 0, out-data: $env.CERT} | to json --raw) }
            _ => {}
        }'
    pct: '
        if ($args | get 0) == "pull" {
            if $env.GUEST != "lxc" { exit 1 }
            $env.CERT | save --force ($args | get 3)
        }'
    pveum: '
        let call = $args | first 2 | str join " "
        if $call == "acl list" {
            print (if $env.ACL == "1" { "[{\"ugid\": \"admins-lldap\", \"path\": \"/\", \"roleid\": \"Administrator\"}]" } else { "[]" })
        } else if $call in ["realm list" "group list" "user list" "pool list" "role list" "user token"] {
            print (if ($args | get --optional 2) == "add" { "{\"value\": \"secret\"}" } else { "[]" })
        }'
    pvesh: '
        if ($args | get 0) == "get" {
            let path = $args | get 1
            print (if $path == "/cluster/firewall/rules" { "[{\"pos\": 0}, {\"pos\": 1}, {\"pos\": 2}]" } else if ($path | str ends-with /firewall/options) { $env.FW_OPTIONS } else { "[]" })
        }'
    ifreload: ''
    sysctl: ''
    modprobe: 'if ($env.WATCHDOG? | default up) != "up" { exit 1 }'
    dpkg-query: 'print -n "not-installed"'
    apt-get: 'if $env.MIRROR != "up" { exit 1 }'
    # -O <file> <url>: the archive github serves, never the pinned one
    wget: '
        if $env.GITHUB != "up" { exit 1 }
        "tampered\n" | save --force ($args | get (($args | enumerate | where item == "-O" | get 0.index) + 1))'
    # BULK_PV is the bulk group's pv; under an LVM_SYSTEM_DIR it shows the groups that config's filter lets through
    pvs: '
        if ($env.LVM_SYSTEM_DIR? | is-empty) {
            print $"  ($env.BULK_PV) bulk\n  /dev/nvme0n1p3 pve"
            return
        }
        if $env.LVM_PVE == "1" { print "  pve" }
        let conf = open --raw ($env.LVM_SYSTEM_DIR | path join lvm.conf)
        if $env.LVM_FILTERS == "0" or not ($conf | str contains $"r|^($env.BULK_PV)$|") { print "  bulk" }'
    hostname: 'print $env.NODE'
    sshd: '
        if ($args | get 0) == "-t" and $env.SSHD_VALID != "1" { exit 255 }
        if ($args | get 0) == "-T" { print (if $env.SSHD_READS == "1" { "permitrootlogin without-password\npasswordauthentication no" } else { "permitrootlogin yes\npasswordauthentication yes" }) }'
    uname: 'print $env.KERNEL'
    nvme: '
        if ($args | get 0) == "list" { print "{\"Devices\": [{\"DevicePath\": \"/dev/nvme1n1\"}, {\"DevicePath\": \"/dev/nvme0n1\"}]}"; return }
        let used = if ($args | get 1) == "/dev/nvme1n1" { 3 } else { 0 }
        print ({thm_temp1_total_time: 40, thm_temp2_total_time: $used, warning_temp_time: $used} | to json)'
    # the kernel lines of this boot that match, none: exit 1 as journalctl does
    journalctl: '
        if $env.MCE_LINES == "0" { exit 1 }
        1..($env.MCE_LINES | into int) | each { "mce: [Hardware Error]: Machine check events logged" } | str join "\n" | print'
    # the resolver reads HOSTS_FILE
    getent: '
        let line = open --raw $env.HOSTS_FILE | lines | each { split row --regex "\\s+" } | where { $env.NODE in ($in | skip 1) } | get --optional 0
        if $line != null { print $"($line.0)  STREAM ($env.NODE)" }'
    ip: 'print $"2: vmbr0    inet ($env.LOCAL_IP)/24 brd 192.168.178.255 scope global vmbr0"'
    openssl: 'print $"X509v3 Subject Alternative Name: \n    IP Address:127.0.0.1, DNS:localhost, IP Address:(open --raw $env.CERT_IP_FILE)"'
    # pvecm signs the address the name resolves to
    pvecm: '
        let resolved = ^getent ahostsv4 $env.NODE
        $resolved | split row " " | first | save --force $env.CERT_IP_FILE'
    systemctl: '
        let call = $args | str join " "
        if ($call | str starts-with "is-enabled ") { print $env.IPMI_STATE }
        if ($call | str starts-with "-q is-failed ") and $env.IPMI_FAILED != "1" { exit 1 }'
}

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def stubs-write [dir: path, calls: path]: nothing -> nothing {
    mkdir $dir
    for stub in ($STUBS | transpose name body) {
        let file = $dir | path join $stub.name
        [
            $"#!($nu.current-exe) --no-config-file"
            "def --wrapped main [...args: string] {"
            ('    $"' + $stub.name + ' ($args | str join (char space))\n" | save --append ' + ($calls | to nuon))
            $stub.body
            "}"
        ] | str join "\n" | save --force $file
        ^chmod +x $file
    }
}

def main [script: path]: nothing -> nothing {
    let t = mktemp --directory --tmpdir
    let calls = $t | path join calls
    let stubs = $t | path join stubs
    stubs-write $stubs $calls
    let script = $script | path expand
    let host = {
        token_dir: ($t | path join tokens)
        templates: [($t | path join nixos.img) ($t | path join nixos-homelab.tar.xz)]
        proxmox_ip: $PROXMOX_IP, router_ip: $ROUTER_IP, lab_subnets: [10.100.0.0/24 10.200.0.0/24]
        zone_bridges: [vmbr1], wake_zones: [internal], nas_id: 104, root_password: x, root_keys: [key]
        gpu_ids: [], bulk_disk: ""
        lldap: {vmid: 101, host: 10.100.0.101, port: 6360, base_dn: "dc=lab", admin_group: admins, cert: /var/lib/lldap/ldaps-cert.pem, bind_user: proxmox-bind, bind_password: y}
        network_interfaces: ($t | path join interfaces)
        hosts_file: ($t | path join hosts)
        corosync_conf: ($t | path join corosync.conf)
        api_cert: ($t | path join pve-ssl.pem)
        api_custom_cert: ($t | path join pveproxy-ssl.pem)
        realm_password_file: ($t | path join realm lldap.pw)
        realm_ca_file: ($t | path join realm lldap-ca.pem)
        ipmi_dmi_entry: ($t | path join dmi-38-0)
        pvestatd_lvm_dir: ($t | path join lvm-pvestatd)
        pvestatd_dropin_dir: ($t | path join pvestatd.service.d)
        disk_by_id_dir: ($t | path join by-id)
        recovery_sysctl_file: ($t | path join 90-homelab-recovery.conf)
        watchdog_defaults: ($t | path join pve-ha-manager)
        watchdog_class_dir: ($t | path join watchdog)
        watchdog_modprobe_conf: ($t | path join homelab-watchdog.conf)
        sshd_dropin: ($t | path join 10-homelab.conf)
        lab_route_unit: ($t | path join homelab-lab-route.service)
        journal_upload: "http://10.100.0.103:19532", journal_upload_dropin: ($t | path join journal-upload.conf.d homelab.conf)
        boot_dir: ($t | path join boot)
        ossec_dir: ($t | path join ossec)
    }
    let bulk_pv = $t | path join dev sdb
    let cert_ip_file = $t | path join cert-ip
    let env_base = {
        PATH: ($env.PATH | prepend $stubs), CALLS: $calls, CERT: $CERT, NODE: $NODE, HOSTS_FILE: $host.hosts_file
        BULK_PV: $bulk_pv, CERT_IP_FILE: $cert_ip_file
        GUEST: down, ACL: "0", MIRROR: up, GITHUB: up, WATCHDOG: up, IPMI_STATE: enabled, IPMI_FAILED: "0"
        FW_OPTIONS: "{}", SSHD_VALID: "1", SSHD_READS: "1", KERNEL: "6.14.8-2-pve"
        LVM_PVE: "1", LVM_FILTERS: "1", LOCAL_IP: $PROXMOX_IP, MCE_LINES: "0"
    }

    # <code> against the host record, its calls logged afresh: {exit_code, stdout, stderr}
    let run = {|code: string, knobs: record|
        "" | save --force $calls
        let source = $"use ($script | to nuon) *\nlet host = $env.PVE_TEST_HOST | from nuon\n($code)"
        with-env ($env_base | merge $knobs | merge {PVE_TEST_HOST: ($host | to nuon)}) {
            do { ^$nu.current-exe --no-config-file -c $source } | complete
        }
    }
    let ok = {|ran: record, what: string| if $ran.exit_code != 0 { fail $"($what): ($ran.stderr)" } }
    let failed = {|ran: record, what: string, says: string|
        if $ran.exit_code == 0 { fail $what }
        if not ($ran.stderr | str contains $says) { fail $"($what): no error saying ($says): ($ran.stderr)" }
    }
    let called = {|call: string, what: string|
        let log = open --raw $calls
        if not ($log | str contains $call) { fail $"($what): no call '($call)' in: ($log)" }
    }
    let not_called = {|call: string, what: string|
        if (open --raw $calls | str contains $call) { fail $"($what): unexpected call '($call)'" }
    }

    let ran = do $run "realm-converge $host" {GUEST: down, ACL: "1"}
    do $ok $ran "no certificate"
    do $called "pveum acl delete / --groups admins-lldap --roles Administrator" "no certificate: the group's admin goes"
    do $not_called "pveum realm" "no certificate: the realm is left alone"
    if not ($ran.stderr | str contains "administers nothing") { fail "no certificate: no warning" }

    do $ok (do $run "realm-converge $host" {GUEST: down, ACL: "0"}) "no certificate and no grant"
    do $not_called "acl delete" "no certificate and no grant: nothing to revoke"

    for guest in [vm lxc] {
        rm --recursive --force ($t | path join realm)
        do $ok (do $run "realm-converge $host" {GUEST: $guest}) $guest
        do $called $"pveum realm add lldap --type ldap --server1 10.100.0.101 --port 6360 --mode ldaps --verify 1 --capath ($host.realm_ca_file)" $"($guest): ldaps, verified"
        do $called "--tfa type=oath" $"($guest): a second factor"
        do $called "pveum acl modify / --groups admins-lldap --roles Administrator" $"($guest): the group administers"
        if (open --raw $host.realm_ca_file | str trim) != $CERT { fail $"($guest): the realm does not trust the guest's own certificate" }
    }

    # <the name's address> <the interfaces' address> <the certificate's address>
    let address_reset = {|name_ip: string, local_ip: string, cert_ip: string|
        rm --force $host.corosync_conf $host.api_custom_cert
        $"127.0.0.1 localhost\n($name_ip) ($NODE).lan ($NODE)\n" | save --force $host.hosts_file
        $cert_ip | save --force $cert_ip_file
        {LOCAL_IP: $local_ip}
    }
    let both = "hosts-converge $host\napi-cert-converge $host"

    let knobs = do $address_reset $PROXMOX_IP $PROXMOX_IP $PROXMOX_IP
    do $ok (do $run $both $knobs) "converged"
    do $not_called "systemctl restart pve-cluster" "converged: pmxcfs restarted"
    do $not_called "pvecm" "converged: the certificate re-signed"

    let knobs = do $address_reset $INSTALLER_IP $PROXMOX_IP $INSTALLER_IP
    do $ok (do $run $both $knobs) "moved address"
    if $"($PROXMOX_IP) ($NODE).lan ($NODE)" not-in (open --raw $host.hosts_file | lines) { fail "moved address: the name still resolves to the old address" }
    do $called "systemctl restart pve-cluster" "moved address: pmxcfs keeps the old address"
    do $called "pvecm updatecerts --force" "moved address: the certificate is not re-signed"
    do $called "systemctl restart pveproxy" "moved address: pveproxy serves the old certificate"
    if (open --raw $cert_ip_file | str trim) != $PROXMOX_IP { fail $"moved address: the certificate names (open --raw $cert_ip_file)" }

    let knobs = do $address_reset $INSTALLER_IP $INSTALLER_IP $INSTALLER_IP
    do $failed (do $run "hosts-converge $host" $knobs) "an address no interface holds was written" "no interface"
    if $"($INSTALLER_IP) ($NODE).lan ($NODE)" not-in (open --raw $host.hosts_file | lines) { fail "an address no interface holds: the hosts file changed" }

    let knobs = do $address_reset $INSTALLER_IP $PROXMOX_IP $INSTALLER_IP
    touch $host.corosync_conf
    do $failed (do $run "hosts-converge $host" $knobs) "a cluster node's address was changed" "in a cluster"
    do $not_called "systemctl restart pve-cluster" "a cluster node: pmxcfs restarted"

    let knobs = do $address_reset $PROXMOX_IP $PROXMOX_IP $INSTALLER_IP
    touch $host.api_custom_cert
    do $failed (do $run "api-cert-converge $host" $knobs) "an uploaded certificate was kept" "pvenode cert delete"
    do $not_called "pvecm" "an uploaded certificate: re-signed anyway"

    # the bulk pv with two by-id names, one unrelated disk
    let by_id = $host.disk_by_id_dir
    let lvm_reset = {||
        rm --recursive --force ($t | path join dev) $by_id
        mkdir ($t | path join dev) $by_id
        touch $bulk_pv ($t | path join dev nvme0n1)
        ^ln -s ../dev/sdb ($by_id | path join ata-WDC_WD40-1)
        ^ln -s ../dev/sdb ($by_id | path join wwn-0x50014ee2)
        ^ln -s ../dev/nvme0n1 ($by_id | path join nvme-Samsung_980)
    }
    let conf_filter = {||
        let read = with-env {LVM_SYSTEM_DIR: $host.pvestatd_lvm_dir} { do { ^lvmconfig devices/global_filter } | complete }
        $read.stdout
    }
    let lvm = "pvestatd-lvm-converge $host"

    do $lvm_reset
    do $ok (do $run $lvm {}) "a new lvm view"
    for name in [$bulk_pv ($by_id | path join ata-WDC_WD40-1) ($by_id | path join wwn-0x50014ee2)] {
        if not (do $conf_filter | str contains $"\"r|^($name)$|\"") { fail $"lvm reads no reject of ($name) from: (do $conf_filter)" }
    }
    if not (do $conf_filter | str contains '"r|/dev/zd.*|","r|/dev/rbd.*|"') { fail $"pve-manager's own rejects are gone: (do $conf_filter)" }
    if (do $conf_filter | str contains nvme) { fail $"another disk is rejected: (do $conf_filter)" }
    let dropin = open --raw ($host.pvestatd_dropin_dir | path join homelab-no-hdd.conf) | lines
    if $"Environment=LVM_SYSTEM_DIR=($host.pvestatd_lvm_dir)" not-in $dropin { fail "pvestatd runs without its lvm view" }
    do $called "systemctl restart pvestatd" "a new lvm view: pvestatd not restarted"

    do $lvm_reset
    do $ok (do $run $lvm {}) "an unchanged lvm view"
    do $not_called "restart pvestatd" "an unchanged lvm view: pvestatd restarted"
    if ($"($host.pvestatd_lvm_dir).new" | path exists) { fail "an unchanged lvm view: the candidate stays" }

    do $lvm_reset
    ^ln -s ../dev/sdb ($by_id | path join ata-WDC_WD40-1-part1-alias)
    do $ok (do $run $lvm {}) "a new name of the bulk pv"
    if not (do $conf_filter | str contains ata-WDC_WD40-1-part1-alias) { fail "a new name of the bulk pv is not rejected" }
    do $not_called "restart pvestatd" "a changed filter: pvestatd restarted (lvm reads its config per call)"

    let installed = open --raw ($host.pvestatd_lvm_dir | path join lvm.conf)
    for bad in [[filters pve what says]; ["0" "1" "still sees the bulk pv" "does not reject the bulk pv"] ["1" "0" "loses the pve group" "pve volume group is gone"]] {
        do $lvm_reset
        do $failed (do $run $lvm {LVM_FILTERS: $bad.filters, LVM_PVE: $bad.pve}) $"an lvm view that ($bad.what) was installed" $bad.says
        if (open --raw ($host.pvestatd_lvm_dir | path join lvm.conf)) != $installed { fail $"an lvm view that ($bad.what) replaced the last good one" }
        if ($"($host.pvestatd_lvm_dir).new" | path exists) { fail $"an lvm view that ($bad.what): the candidate stays" }
    }

    # a disk name with a quote in it renders an lvm.conf lvm cannot parse
    do $lvm_reset
    ^ln -s ../dev/sdb ($by_id | path join 'quote"d')
    do $failed (do $run $lvm {}) "an lvm.conf lvm cannot parse was installed" "cannot read"
    if (open --raw ($host.pvestatd_lvm_dir | path join lvm.conf)) != $installed { fail "an lvm.conf lvm cannot parse replaced the last good one" }

    rm --force $host.ipmi_dmi_entry
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: enabled, IPMI_FAILED: "1"}) "no bmc"
    do $called "systemctl mask --now openipmi.service" "no bmc: openipmi still starts"
    do $called "systemctl reset-failed openipmi.service" "no bmc: openipmi stays failed"
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: masked}) "masked"
    do $not_called "mask" "masked: masked again"
    touch $host.ipmi_dmi_entry
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: enabled}) "a bmc"
    do $not_called "mask" "a bmc: openipmi masked"

    # <identity> <state> per watchdog device
    let watchdogs_reset = {|devices: list<list<string>>|
        rm --recursive --force $host.watchdog_class_dir
        for device in ($devices | enumerate) {
            let dir = $host.watchdog_class_dir | path join $"watchdog($device.index)"
            mkdir $dir
            $"($device.item.0)\n" | save ($dir | path join identity)
            $"($device.item.1)\n" | save ($dir | path join state)
        }
    }
    do $watchdogs_reset [["Software Watchdog" active] ["SP5100 TCO timer" inactive]]
    "# WATCHDOG_MODULE=ipmi_watchdog\nOTHER=1\n" | save --force $host.watchdog_defaults
    let ran = do $run "recovery-converge $host" {}
    do $ok $ran "recovery"
    if not ($ran.stderr | str contains "feeds Software Watchdog, not the SP5100 TCO timer") { fail $"softdog fed: no warning: ($ran.stderr)" }
    let sysctl = open --raw $host.recovery_sysctl_file | lines
    for want in ["kernel.panic = 10" "kernel.panic_on_oops = 1" "kernel.hung_task_panic = 1" "kernel.softlockup_panic = 1" "kernel.hardlockup_panic = 1"] {
        if $want not-in $sysctl { fail $"recovery: ($want) missing from ($sysctl)" }
    }
    do $called $"sysctl -q -p ($host.recovery_sysctl_file)" "recovery: the settings wait for a reboot"
    if (open --raw $host.watchdog_defaults) != "OTHER=1\nWATCHDOG_MODULE=sp5100_tco\n" {
        fail $"recovery: watchdog-mux feeds another watchdog: (open --raw $host.watchdog_defaults)"
    }
    if (open --raw $host.watchdog_modprobe_conf) != "blacklist softdog\ninstall softdog /bin/false\n" {
        fail $"recovery: softdog still loads at boot: (open --raw $host.watchdog_modprobe_conf)"
    }
    do $watchdogs_reset [["Software Watchdog" inactive] ["SP5100 TCO timer" active]]
    let ran = do $run "recovery-converge $host" {}
    do $ok $ran "recovery again"
    do $not_called "sysctl" "recovery: unchanged settings applied again"
    if ($ran.stderr | str contains "feeds") { fail $"the hardware watchdog fed: warned anyway: ($ran.stderr)" }
    # the chipset's watchdog gone after a converge armed it (a firmware toggle): mux falls back to softdog again
    let ran = do $run "recovery-converge $host" {WATCHDOG: down}
    do $ok $ran "no hardware watchdog: the converge stops"
    if not ($ran.stderr | str contains "power cycle") { fail "no hardware watchdog: no warning" }
    if (open --raw $host.watchdog_defaults) != "OTHER=1\n" { fail "no hardware watchdog: watchdog-mux still pointed at it" }
    if ($host.watchdog_modprobe_conf | path exists) { fail "no hardware watchdog: softdog blocked with nothing to replace it" }

    let sshd = "sshd-converge $host"
    do $ok (do $run $sshd {}) "keys only"
    if (open --raw $host.sshd_dropin | lines) != ["PermitRootLogin prohibit-password" "PasswordAuthentication no" "KbdInteractiveAuthentication no"] {
        fail $"keys only: the drop-in reads (open --raw $host.sshd_dropin)"
    }
    do $called "systemctl reload ssh" "keys only: sshd keeps accepting passwords until it reloads"
    do $ok (do $run $sshd {}) "keys only again"
    do $not_called "reload ssh" "keys only again: sshd reloaded"
    rm $host.sshd_dropin
    do $failed (do $run $sshd {SSHD_VALID: "0"}) "a config sshd refuses was kept" "refuses"
    if ($host.sshd_dropin | path exists) { fail "a config sshd refuses: the drop-in stays" }
    do $not_called "reload ssh" "a config sshd refuses: sshd reloaded"
    do $failed (do $run $sshd {SSHD_READS: "0"}) "a drop-in sshd ignores passed" "includes no sshd_config.d"
    rm $host.sshd_dropin

    do $ok (do $run "lab-route-converge $host" {}) "the lab's route"
    let unit = open --raw $host.lab_route_unit | lines
    for subnet in $host.lab_subnets {
        if $"ExecStart=/usr/sbin/ip route replace ($subnet) via ($ROUTER_IP)" not-in $unit { fail $"the lab's route: ($subnet) is not routed: ($unit)" }
    }
    do $called "systemctl restart homelab-lab-route.service" "the lab's route: not applied now"
    do $ok (do $run "lab-route-converge $host" {}) "the lab's route again"
    do $not_called "restart homelab-lab-route" "the lab's route again: restarted"

    do $ok (do $run "firewall-backend-converge" {FW_OPTIONS: "{}"}) "iptables backend"
    do $called $"pvesh set /nodes/($NODE)/firewall/options --nftables 1" "iptables backend: kept"
    do $ok (do $run "firewall-backend-converge" {FW_OPTIONS: '{"nftables": 1}'}) "nftables backend"
    do $not_called "pvesh set" "nftables backend: set again"

    do $ok (do $run "journal-upload-converge $host" {}) "the journal upload"
    if (open --raw $host.journal_upload_dropin | lines) != ["[Upload]" "URL=http://10.100.0.103:19532"] {
        fail $"the journal upload: the drop-in reads (open --raw $host.journal_upload_dropin)"
    }
    do $called "systemctl restart systemd-journal-upload" "the journal upload: the old url stays until a restart"
    do $ok (do $run "journal-upload-converge $host" {}) "the journal upload again"
    do $not_called "restart systemd-journal-upload" "the journal upload again: restarted"

    let textfiles = $t | path join textfiles
    mkdir $textfiles
    # <the function printing the script> <args> <env>: what it wrote to the textfile directory
    let textfile_run = {|script: string, file: string, knobs: record|
        let ran = do $run $"($script) | save --force ($t | path join script.nu)" {}
        do $ok $ran $script
        # smartd runs its script without an environment of its own, so the directory is written into it
        let source = open --raw ($t | path join script.nu) | str replace $TEXTFILE_DIR_HOST $textfiles
        $source | save --force ($t | path join script.nu)
        let wrote = with-env ($env_base | merge {TEXTFILE_DIR: $textfiles} | merge $knobs) {
            do { ^$nu.current-exe --no-config-file ($t | path join script.nu) } | complete
        }
        do $ok $wrote $"($script) ran"
        open --raw ($textfiles | path join $file) | lines | where { not ($in | str starts-with "#") }
    }

    let gauges = do $textfile_run hardware-metrics hardware.prom {MCE_LINES: "0"}
    let want = [
        'homelab_nvme_thermal_throttle_seconds_total{device="nvme0n1"} 40'
        'homelab_nvme_warning_temperature_seconds_total{device="nvme0n1"} 0'
        'homelab_nvme_thermal_throttle_seconds_total{device="nvme1n1"} 43'
        'homelab_nvme_warning_temperature_seconds_total{device="nvme1n1"} 180'
        'homelab_mce_events_total 0'
    ]
    if $gauges != $want { fail $"hardware metrics: ($gauges)" }
    let gauges = do $textfile_run hardware-metrics hardware.prom {MCE_LINES: "2"}
    if 'homelab_mce_events_total 2' not-in $gauges { fail $"machine checks: ($gauges)" }

    let smartd_env = {
        SMARTD_DEVICE: /dev/nvme1, SMARTD_FAILTYPE: Health
        SMARTD_MESSAGE: "Device: /dev/nvme1, \"hot\" Critical Warning (0x02): Temperature\nsecond line"
    }
    let gauges = do $textfile_run smartd-textfile smartd-_dev_nvme1_Health.prom $smartd_env
    let label = 'message="Device: /dev/nvme1, \"hot\" Critical Warning (0x02): Temperature"'
    if not ($gauges | any { str contains $'device="/dev/nvme1",type="Health",($label)' }) {
        fail $"smartd warning: the message is not its first line, escaped: ($gauges)"
    }

    mkdir $host.boot_dir
    touch ($host.boot_dir | path join vmlinuz-6.14.8-2-pve) ($host.boot_dir | path join vmlinuz-6.14.11-9-pve)
    let ran = do $run "upgrade $host" {}
    do $ok $ran "upgrade"
    do $called "full-upgrade -y" "upgrade: no full-upgrade"
    do $called "-o Dpkg::Options::=--force-confold" "upgrade: the host's config files are replaced"
    if not ($ran.stdout | str contains "REBOOT the host to run kernel 6.14.11-9-pve") { fail $"upgrade: no reboot named: ($ran.stdout)" }
    let ran = do $run "upgrade $host" {KERNEL: "6.14.11-9-pve"}
    if ($ran.stdout | str contains REBOOT) { fail $"upgrade on the newest kernel: a reboot named: ($ran.stdout)" }
    do $failed (do $run "upgrade $host" {MIRROR: down}) "upgrade with the mirrors down passed" "nothing upgraded"
    do $not_called "full-upgrade" "upgrade with the mirrors down: upgraded from a stale index"

    "auto vmbr0\niface vmbr0 inet static\n\nauto vmbr1\niface vmbr1 inet manual\n\n" | save --force $host.network_interfaces
    touch ...$host.templates
    do $ok (do $run "teardown $host" {}) "teardown"
    do $called "pvesh set /cluster/firewall/options --enable 0" "teardown: the datacenter firewall stays on"
    let deleted = open --raw $calls | parse --regex 'pvesh delete /cluster/firewall/rules/(?<pos>[0-9]+)' | get pos | str join
    if $deleted != "210" { fail $"teardown: the cluster rules are not deleted last position first: ($deleted)" }
    if ($host.templates | any { path exists }) { fail "teardown: the templates stay" }
    let interfaces = open --raw $host.network_interfaces | lines
    if "auto vmbr0" not-in $interfaces { fail "teardown: the installer's bridge went" }
    if ($interfaces | any { str contains vmbr1 }) { fail "teardown: a zone bridge stays" }
    do $called "apt-get purge -y prometheus-node-exporter" "teardown: the exporter stays"

    do $ok (do $run "if (packages-install [jq]) { exit 1 }" {MIRROR: down}) "mirror down: packages-install reports success"

    let ran = do $run "ossec-converge $host" {MIRROR: down}
    do $ok $ran "mirror down: ossec-converge stops the converge"
    if not ($ran.stderr | str contains unavailable) { fail "mirror down: no warning" }
    do $not_called "wget -q" "mirror down: github fetched anyway"

    let ran = do $run "ossec-converge $host" {MIRROR: up, GITHUB: down}
    do $ok $ran "github down: ossec-converge stops the converge"
    if not ($ran.stderr | str contains unavailable) { fail "github down: no warning" }
    if ($host.ossec_dir | path join etc | path exists) { fail "github down: configured an OSSEC that is not installed" }

    # a tampered archive is no outage: it stops the run
    do $failed (do $run "ossec-converge $host" {MIRROR: up, GITHUB: up}) "a tampered archive was installed" "does not match its pinned sha256"

    rm --recursive --force $t
    print "pve-install: all cases pass"
}
