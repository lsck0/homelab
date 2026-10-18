#!/usr/bin/env -S nu --no-config-file
# scripts/pve-install.nu's own decisions, with the Proxmox and Debian tools stubbed: the lldap realm fails closed
# without the guest's certificate and binds over ldaps with it; pvestatd's lvm config is written whole, read back by
# lvm's own parser and installed only when it rejects every name of the bulk pv; openipmi is masked only on a host
# without a bmc; the node's name moves to its lan address only on a standalone host that holds it, and the api
# certificate is re-signed only when it does not name that address; the recovery settings reboot a hung host; an
# unavailable package mirror or github leaves the host exporter and OSSEC for the next run instead of stopping the
# converge.
#
# Each case runs the script's functions in a nu of its own, so its exit and stderr are the converge's. The stubs are
# nu scripts first on PATH; they log every call to $CALLS and answer by the env the case sets:
#   GUEST          vm, lxc or down: how the lldap guest answers
#   ACL            1 when the realm's group already administers /
#   MIRROR GITHUB  up or down
#   WATCHDOG       up, or down when the chipset's watchdog does not load
#   IPMI_STATE     what is-enabled prints for openipmi; IPMI_FAILED 1 when it failed
#   LVM_PVE        1 when the pve group is seen; LVM_FILTERS 1 when lvm applies the config's filter
#   LOCAL_IP       what the interfaces hold
# The certificate's address is state pvecm changes, so it lives in a file.
#
# usage: pve_install_test.nu <scripts/pve-install.nu>

const NODE = "luca-server"
const PROXMOX_IP = "192.168.178.200"
const INSTALLER_IP = "192.168.178.2"
const CERT = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"

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
            print (if ($args | get 1) == "/cluster/firewall/rules" { "[{\"pos\": 0}, {\"pos\": 1}, {\"pos\": 2}]" } else { "[]" })
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
        proxmox_ip: $PROXMOX_IP, zone_bridges: [vmbr1], wake_zones: [internal], nas_id: 104, root_password: x, root_keys: [key]
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
        ossec_dir: ($t | path join ossec)
    }
    let bulk_pv = $t | path join dev sdb
    let cert_ip_file = $t | path join cert-ip
    let env_base = {
        PATH: ($env.PATH | prepend $stubs), CALLS: $calls, CERT: $CERT, NODE: $NODE, HOSTS_FILE: $host.hosts_file
        BULK_PV: $bulk_pv, CERT_IP_FILE: $cert_ip_file
        GUEST: down, ACL: "0", MIRROR: up, GITHUB: up, WATCHDOG: up, IPMI_STATE: enabled, IPMI_FAILED: "0"
        LVM_PVE: "1", LVM_FILTERS: "1", LOCAL_IP: $PROXMOX_IP
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

    # -------------------------------------------------------------------------
    # the realm
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # the node's address and the api certificate
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # pvestatd's lvm view
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # the host's own units
    # -------------------------------------------------------------------------
    rm --force $host.ipmi_dmi_entry
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: enabled, IPMI_FAILED: "1"}) "no bmc"
    do $called "systemctl mask --now openipmi.service" "no bmc: openipmi still starts"
    do $called "systemctl reset-failed openipmi.service" "no bmc: openipmi stays failed"
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: masked}) "masked"
    do $not_called "mask" "masked: masked again"
    touch $host.ipmi_dmi_entry
    do $ok (do $run "ipmi-converge $host" {IPMI_STATE: enabled}) "a bmc"
    do $not_called "mask" "a bmc: openipmi masked"

    "# WATCHDOG_MODULE=ipmi_watchdog\nOTHER=1\n" | save --force $host.watchdog_defaults
    do $ok (do $run "recovery-converge $host" {}) "recovery"
    let sysctl = open --raw $host.recovery_sysctl_file | lines
    for want in ["kernel.panic = 10" "kernel.panic_on_oops = 1" "kernel.hung_task_panic = 1" "kernel.softlockup_panic = 1"] {
        if $want not-in $sysctl { fail $"recovery: ($want) missing from ($sysctl)" }
    }
    do $called $"sysctl -q -p ($host.recovery_sysctl_file)" "recovery: the settings wait for a reboot"
    if (open --raw $host.watchdog_defaults) != "OTHER=1\nWATCHDOG_MODULE=sp5100_tco\n" {
        fail $"recovery: watchdog-mux feeds another watchdog: (open --raw $host.watchdog_defaults)"
    }
    do $ok (do $run "recovery-converge $host" {}) "recovery again"
    do $not_called "sysctl" "recovery: unchanged settings applied again"
    "OTHER=1\n" | save --force $host.watchdog_defaults
    let ran = do $run "recovery-converge $host" {WATCHDOG: down}
    do $ok $ran "no hardware watchdog: the converge stops"
    if not ($ran.stderr | str contains "power cycle") { fail "no hardware watchdog: no warning" }
    if (open --raw $host.watchdog_defaults) != "OTHER=1\n" { fail "no hardware watchdog: watchdog-mux was pointed at it anyway" }

    # -------------------------------------------------------------------------
    # teardown
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # outages outside the lab
    # -------------------------------------------------------------------------
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
