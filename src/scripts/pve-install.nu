#!/usr/bin/env -S nu --no-config-file --stdin
# converge the Proxmox VE host to what the lab declares; every run of init.nu and sync.nu runs it, reruns change
# nothing. deinit.nu runs its teardown.
#
# usage: pve-install.nu converge|upgrade|teardown, its inputs a json record on stdin, out of argv. lib/proxmox.nu installs the
# pinned nu first (PROXMOX_NU) and runs this file under it:
#   token_dir            where a new api token's secret is left, one file per role
#   templates            the golden image and the lxc template sync.nu uploads
# converge only:
#   proxmox_ip           the host's lan address (site.json), which its api certificate must name
#   router_ip            the lab router's lan address (site.json), the host's route to the lab's subnets
#   lab_subnets          every zone's subnet (zones.json) and the wireguard peers' (the lab export)
#   zone_bridges         every zone's bridge (zones.json); vmbr0 comes from the installer
#   wake_zones           the zones whose ingress wakes onDemand guests (terraform/lib.tf grants each its guests)
#   gpu_ids              the passthrough gpu's functions (site.json), empty for none
#   bulk_disk            the disk the bulk pool is created on; init.nu asks it once, empty keeps the pool as it is
#   nas_id               the nas guest, whose hookscript wakes the bulk pool around its start and stop
#   journal_upload       vm-103's journal-remote url, where the host's journal goes
#   lldap                {vmid host port base_dn admin_group cert bind_user bind_password}: the guest running lldap, its
#                        ldaps listener and self-signed certificate (which the realm pins), the directory and its group
#                        that administers the datacentre, and the read-only user the realm binds as
#   root_password        root@pam's own password (proxmox-root-pass)
#   root_keys            the ssh keys root takes
# An api token is created only when missing, its secret written once to <token_dir>/<role> as "<token id>=<secret>"
# for lib/proxmox.nu to store and delete; an existing token is never rotated.
#
# The lab owns the host: the pve realm's users, the pools, the bridges past vmbr0 and the roles are exactly the
# declared ones, so leftovers of earlier layouts go on the next run. The package mirrors and github are outside the
# lab: while one is unavailable, what needs it is left for the next run and the rest converges. Every function takes
# the host record (pve-host plus the inputs), so tests/pve_install_test.nu runs them against its own paths.

const PACKAGES = [
    prometheus-node-exporter prometheus-node-exporter-collectors smartmontools nvme-cli rasdaemon jq systemd-journal-remote
]
const OSSEC_BUILD_PACKAGES = [build-essential libevent-dev libpcre2-dev libz-dev libssl-dev libsystemd-dev wget ca-certificates]
# a mirror or github that does not answer costs a run at most this, per try
const APT_OPTIONS = [-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=3]
const DOWNLOAD_TIMEOUT_S = 30
const DOWNLOAD_TRIES = 3
# debian's textfile directory: its collector timers write there, and so do the gauges below
const TEXTFILE_DIR = "/var/lib/prometheus/node-exporter"
const TEXTFILE_INTERVAL_MIN = 5
# hdparm -S units of 5 s: 10 minutes
const HDD_SPINDOWN_SETTING = 120
const IPMI_UNIT = "openipmi.service"
# containers cannot load kernel modules: nfs for the privileged ones' mounts, overlay and br_netfilter for podman
const LXC_MODULES = [nfs nfsv4 overlay br_netfilter]
const WAKE_ROLE = "HomelabWake"
const WAKE_PRIVILEGES = "VM.Audit,VM.PowerMgmt"
const REALM = "lldap"
const REALM_SYNC_SCHEDULE = "hourly"
# a realm login asks for a totp code too; root@pam sets each user's key (FEATURES.md, "Proxmox host")
const REALM_TFA = "type=oath"
const CERT_BEGIN = "-----BEGIN CERTIFICATE-----"
const GUEST_EXEC_TIMEOUT_S = 10
const BRIDGE_PATTERN = '^auto (vmbr[1-9][0-9]*)$'
const SYS_NET_DIR = "/sys/class/net"
const STORAGE_CFG = "/etc/pve/storage.cfg"
const SNIPPETS_DIR = "/var/lib/vz/snippets"
# bulk (hdd) stays disabled in proxmox: pvestatd polls enabled storages every 10s, which keeps the disk spinning;
# the nas guest's hookscript enables it only around its own start and stop
const BULK_HOOK_NAME = "homelab-bulk.nu"
const PVE_GUESTS_DROPIN = "/etc/systemd/system/pve-guests.service.d/homelab-bulk.conf"
# pve-manager's own global_filter: zfs zvols and ceph rbds are never pvs
const PVE_LVM_REJECTS = ['r|/dev/zd.*|' 'r|/dev/rbd.*|']
# of the bulk disk, the thin pool takes this much; the rest keeps full thin metadata from wedging the pool
const BULK_POOL_EXTENTS = "99%FREE"
const OSSEC_VERSION = "3.8.0"
# sha256 of github's source archive of that tag, checked before anything of it runs as root
const OSSEC_SHA256 = "bd857a2dd7d0559ef59b4a9ec276f3a8ade6830f8aed257e8f4a62106cfe5f38"
const OSSEC_URL = $"https://github.com/ossec/ossec-hids/archive/refs/tags/($OSSEC_VERSION).tar.gz"
const OSSEC_MANAGED_MARK = "homelab-managed"
# 6h not 12h: catch /etc/pve changes the same day
const OSSEC_FREQUENCY_DEFAULT = "<frequency>43200</frequency>"
const OSSEC_FREQUENCY = "<frequency>21600</frequency>"
const OSSEC_WATCH = '  <!-- homelab-managed: see src/scripts/pve-install.nu -->
  <syscheck>
    <directories check_all="yes" realtime="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin</directories>
    <!-- the cluster filesystem: guest configs, api tokens, acls -->
    <directories check_all="yes" realtime="yes">/etc/pve</directories>
    <!-- rewritten constantly -->
    <ignore>/etc/pve/.version</ignore>
    <ignore>/etc/pve/.members</ignore>
    <ignore>/etc/pve/.rrd</ignore>
    <ignore>/etc/pve/.vmlist</ignore>
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/adjtime</ignore>
  </syscheck>
'
# a panic or a stalled kernel reboots the host instead of waiting for a power cycle; a hard lockup is the nmi
# watchdog's to catch
const RECOVERY_SYSCTL = [
    "kernel.panic = 10" "kernel.panic_on_oops = 1" "kernel.hung_task_panic = 1" "kernel.softlockup_panic = 1"
    "kernel.hardlockup_panic = 1"
]
# a kernel hang stops every software timer, so only the chipset's watchdog resets the board. watchdog-mux
# (pve-ha-manager) opens /dev/watchdog on every pve host and feeds it, so it is the feeder: systemd's
# RuntimeWatchdogSec would find the device busy. Mux loads its module at boot, so a change arms at the next one.
const WATCHDOG_MODULE = "sp5100_tco"
const WATCHDOG_MODULE_LINE = '^\s*#?\s*WATCHDOG_MODULE='
# what the kernel names that module's device; mux keeps the first watchdog it found at boot open (softdog, until
# the module loads before it)
const WATCHDOG_IDENTITY = "SP5100 TCO timer"
# Debian's own sshd_config includes sshd_config.d first, and sshd keeps the first value it reads
const SSHD_KEYS_ONLY = ["PermitRootLogin prohibit-password" "PasswordAuthentication no" "KbdInteractiveAuthentication no"]
# a full-upgrade keeps every config file the host changed, as an interactive one answering "keep" would
const APT_KEEP_CONFIG = [-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold]

# the host's files this script reads and writes
export def pve-host []: nothing -> record {
    {
        network_interfaces: "/etc/network/interfaces"
        hosts_file: "/etc/hosts"
        # a cluster's nodes are named in it, which this script does not own
        corosync_conf: "/etc/pve/corosync.conf"
        api_cert: "/etc/pve/local/pve-ssl.pem"
        # an uploaded certificate (pvenode cert set, acme) that pveproxy serves instead of the cluster-signed one
        api_custom_cert: "/etc/pve/local/pveproxy-ssl.pem"
        realm_password_file: $"/etc/pve/priv/realm/($REALM).pw"
        realm_ca_file: $"/etc/pve/priv/realm/($REALM)-ca.pem"
        # smbios type 38 describes a bmc; without one debian's openipmi init script fails at every boot
        ipmi_dmi_entry: "/sys/firmware/dmi/entries/38-0"
        # pvestatd's own lvm view (LVM_SYSTEM_DIR), which never reads the bulk disk's labels
        pvestatd_lvm_dir: "/etc/lvm-pvestatd"
        pvestatd_dropin_dir: "/etc/systemd/system/pvestatd.service.d"
        disk_by_id_dir: "/dev/disk/by-id"
        recovery_sysctl_file: "/etc/sysctl.d/90-homelab-recovery.conf"
        watchdog_defaults: "/etc/default/pve-ha-manager"
        watchdog_class_dir: "/sys/class/watchdog"
        sshd_dropin: "/etc/ssh/sshd_config.d/10-homelab.conf"
        lab_route_unit: "/etc/systemd/system/homelab-lab-route.service"
        journal_upload_dropin: "/etc/systemd/journal-upload.conf.d/homelab.conf"
        boot_dir: "/boot"
        ossec_dir: "/var/ossec"
    }
}

def fail [message: string] {
    error make {msg: $message}
}

def warn [message: string]: nothing -> nothing {
    print -e $"WARNING: ($message)"
}

def lines-text [lines: list<string>]: nothing -> string {
    $lines | each { $"($in)\n" } | str join
}

# <path> holds <text>; true when that changed the file
def file-converge [path: path, mode: string, text: string]: nothing -> bool {
    if ($path | path exists) and (open --raw $path) == $text { return false }
    let new = mktemp --tmpdir-path ($path | path dirname) $"($path | path basename).XXXXXX"
    $text | save --force $new
    ^chmod $mode $new
    mv --force $new $path
    true
}

# a nu script for this host, run by the nu running this one
def nu-script [body: string]: nothing -> string {
    $"#!($nu.current-exe) --no-config-file\n($body)"
}

def node-name []: nothing -> string {
    let name = ^hostname
    $name | str trim
}

# pveum and pvesh print json lists
def --wrapped pve-json [...argv: string]: nothing -> any {
    let printed = ^$argv.0 ...($argv | skip 1) --output-format json
    $printed | from json
}

def pve-has [list: list, field: string, value: string]: nothing -> bool {
    $list | any { ($in | get --optional $field) == $value }
}

def pve-user-exists [user: string]: nothing -> bool {
    pve-has (pve-json pveum user list) userid $user
}

def succeeds [argv: list<string>]: nothing -> bool {
    (do { ^$argv.0 ...($argv | skip 1) } | complete).exit_code == 0
}

# the missing ones; false when the mirrors do not answer
export def packages-install [packages: list<string>]: nothing -> bool {
    let missing = $packages | where {|p| (do { ^dpkg-query -W '-f=${Status}' $p } | complete).stdout != "install ok installed" }
    if ($missing | is-empty) { return true }
    print $">>> Proxmox: installing ($missing | str join ' ')"
    with-env {DEBIAN_FRONTEND: noninteractive} {
        if not (succeeds [apt-get ...$APT_OPTIONS update]) { return false }
        succeeds [apt-get ...$APT_OPTIONS install -y ...$missing]
    }
}

# the file as the guest holds it, read through the hypervisor (qemu agent, pct pull) like every guest's ssh host key,
# never over the network; empty when the guest does not answer
def guest-file-read [vmid: string, path: string]: nothing -> string {
    if (succeeds [qm status $vmid]) {
        let out = do { ^qm guest exec $vmid --timeout $GUEST_EXEC_TIMEOUT_S -- cat $path } | complete
        let reply = try { $out.stdout | from json } catch { {} }
        if $out.exit_code != 0 or $reply.exitcode? != 0 { return "" }
        return ($reply | get --optional out-data | default "")
    }
    let tmp = mktemp --tmpdir
    let pulled = succeeds [pct pull $vmid $path $tmp]
    let text = if $pulled { open --raw $tmp } else { "" }
    rm --force $tmp
    $text
}

def --wrapped token-ensure [host: record, role: string, user: string, token: string, ...options: string]: nothing -> nothing {
    if (pve-has (pve-json pveum user token list $user) tokenid $token) { return }
    let secret = pve-json pveum user token add $user $token ...$options | get --optional value | default ""
    if $secret == "" { fail $"Proxmox did not create the api token ($user)!($token)." }
    ^install -d -m 700 $host.token_dir
    let file = $host.token_dir | path join $role
    ^install -m 600 /dev/null $file
    $"($user)!($token)=($secret)\n" | save --append $file
    print $">>> Proxmox: created the api token ($user)!($token)"
}

def unit-restart [unit: string]: nothing -> nothing {
    ^systemctl daemon-reload
    ^systemctl restart $unit
}

# the first sample now, not one interval after a change
def textfile-job-start [name: string]: nothing -> nothing {
    ^systemctl daemon-reload
    ^systemctl enable --now $"($name).timer"
    ^systemctl start $"($name).service"
}

# <script> becomes /usr/local/bin/<name>, run every TEXTFILE_INTERVAL_MIN by a timer with TEXTFILE_DIR in its
# environment
def textfile-job-install [name: string, what: string, boot_delay: string, script: string]: nothing -> nothing {
    let changed = [
        (file-converge $"/usr/local/bin/($name)" "755" $script)
        (file-converge $"/etc/systemd/system/($name).service" "644" (lines-text [
            "[Unit]" $"Description=Publish ($what) for node_exporter"
            "[Service]" "Type=oneshot" $"Environment=TEXTFILE_DIR=($TEXTFILE_DIR)" $"ExecStart=/usr/local/bin/($name)"
        ]))
        (file-converge $"/etc/systemd/system/($name).timer" "644" (lines-text [
            "[Unit]" $"Description=Publish ($what) every ($TEXTFILE_INTERVAL_MIN) minutes"
            "[Timer]" $"OnBootSec=($boot_delay)" $"OnUnitActiveSec=($TEXTFILE_INTERVAL_MIN)m"
            "[Install]" "WantedBy=timers.target"
        ]))
    ]
    if ($changed | any { $in }) { textfile-job-start $name }
}

def apt-sources-converge []: nothing -> nothing {
    let codename = open --raw /etc/os-release | lines | parse 'VERSION_CODENAME={name}' | get 0.name | str trim --char '"'
    # enterprise repos need a paid subscription
    let listed = do { ^grep -rl "enterprise.proxmox.com" /etc/apt/ } | complete
    for file in ($listed.stdout | lines) {
        if ($file | str ends-with ".sources") {
            mv $file $"/root/($file | path basename).disabled"
        } else {
            ^sed -i 's|^.*enterprise\.proxmox\.com.*|# &|g' $file
        }
    }
    file-converge /etc/apt/sources.list.d/pve-no-subscription.list "644" $"deb http://download.proxmox.com/debian/pve ($codename) pve-no-subscription\n" | ignore
}

def bridges-present [interfaces: path]: nothing -> list<string> {
    open --raw $interfaces | lines | parse --regex $BRIDGE_PATTERN | get capture0
}

def bridge-remove [interfaces: path, bridge: string]: nothing -> nothing {
    ^sed -i $"/^auto ($bridge)$/,/^$/d" $interfaces
}

export def bridges-converge [host: record]: nothing -> nothing {
    let file = $host.network_interfaces
    let declared = open --raw $file | lines
    let added = $host.zone_bridges | where {|bridge| $"auto ($bridge)" not-in $declared }
    for bridge in $added {
        $"\nauto ($bridge)\niface ($bridge) inet manual\n    bridge-ports none\n    bridge-stp off\n    bridge-fd 0\n" | save --append $file
    }
    let removed = bridges-present $file | where $it not-in $host.zone_bridges
    for bridge in $removed {
        # a guest still on it would lose its network: that guest is the drift to fix first
        let ports = try { ls ($SYS_NET_DIR | path join $bridge brif) | get name | path basename } catch { [] }
        if ($ports | is-not-empty) { fail $"($bridge) is no zone's bridge but guests are on it: ($ports | str join ' ')" }
        bridge-remove $file $bridge
        print $">>> Proxmox: removed ($bridge), no zone's bridge"
    }
    if ($added | is-not-empty) or ($removed | is-not-empty) { ^ifreload -a }
}

# iommu on, the gpu's functions bound to vfio-pci instead of their drivers; rebuilt now, bound at the next host boot
def gpu-converge [host: record]: nothing -> nothing {
    if ($host.gpu_ids | is-empty) { return }
    let iommu = if (open --raw /proc/cpuinfo | str contains GenuineIntel) { "intel_iommu" } else { "amd_iommu" }
    if not (open --raw /etc/default/grub | str contains $"($iommu)=on") {
        ^sed -i ('s/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 ' + $"($iommu)=on iommu=pt\"/") /etc/default/grub
    }
    let changed = [
        (file-converge /etc/modules-load.d/vfio.conf "644" (lines-text [vfio vfio_iommu_type1 vfio_pci]))
        (file-converge /etc/modprobe.d/vfio.conf "644" $"options vfio-pci ids=($host.gpu_ids | str join ',')\n")
        (file-converge /etc/modprobe.d/blacklist-gpu.conf "644" (lines-text [
            "blacklist nouveau" "blacklist nvidia" "blacklist nvidiafb" "blacklist snd_hda_intel"
        ]))
    ]
    if ($changed | any { $in }) {
        ^update-initramfs -u -k all out> /dev/null
        ^update-grub out> /dev/null
        print ">>> Proxmox: gpu passthrough staged; REBOOT the host to bind vfio-pci."
    }
}

# cpu biased to efficiency, hdds asleep when idle, the containers' kernel modules; now and at every host boot
def power-converge []: nothing -> nothing {
    let tmpfiles = "/etc/tmpfiles.d/homelab-power.conf"
    if (file-converge $tmpfiles "644" (lines-text [
        "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave"
        "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power"
    ])) {
        ^systemd-tmpfiles --create $tmpfiles
    }
    let rule = $"ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"sd[a-z]\", ATTR{queue/rotational}==\"1\", RUN+=\"/usr/sbin/hdparm -S ($HDD_SPINDOWN_SETTING) /dev/%k\"\n"
    # the rule covers disks appearing from now on; the ones present spin down now
    if (file-converge /etc/udev/rules.d/69-homelab-hdd-spindown.rules "644" $rule) {
        for disk in (glob /sys/block/sd*) {
            if (open --raw ($disk | path join queue rotational) | str trim) == "1" {
                ^hdparm -q -S $HDD_SPINDOWN_SETTING $"/dev/($disk | path basename)"
            }
        }
    }
    if (file-converge /etc/modules-load.d/homelab-lxc.conf "644" (lines-text $LXC_MODULES)) {
        for module in $LXC_MODULES { ^modprobe $module }
    }
}

export def ipmi-converge [host: record]: nothing -> nothing {
    if ($host.ipmi_dmi_entry | path exists) { return }
    if not (succeeds [systemctl cat $IPMI_UNIT]) { return }
    if ((do { ^systemctl is-enabled $IPMI_UNIT } | complete).stdout | str trim) != "masked" {
        ^systemctl mask --now $IPMI_UNIT
        print $">>> Proxmox: masked ($IPMI_UNIT), the host has no bmc"
    }
    if (succeeds [systemctl -q is-failed $IPMI_UNIT]) { ^systemctl reset-failed $IPMI_UNIT }
}

# a panic, an oops or a stalled kernel reboots the host; the hardware watchdog catches a hang that never panics
export def recovery-converge [host: record]: nothing -> nothing {
    if (file-converge $host.recovery_sysctl_file "644" (lines-text $RECOVERY_SYSCTL)) {
        ^sysctl -q -p $host.recovery_sysctl_file
        print ">>> Proxmox: a panic, an oops, a hung task or a soft lockup now reboots the host"
    }
    if not (succeeds [modprobe $WATCHDOG_MODULE]) {
        warn $"($WATCHDOG_MODULE) does not load \(disabled in the firmware?\): a hung host still waits for a power cycle"
        return
    }
    let kept = if ($host.watchdog_defaults | path exists) {
        open --raw $host.watchdog_defaults | lines | where $it !~ $WATCHDOG_MODULE_LINE
    } else { [] }
    if (file-converge $host.watchdog_defaults "644" (lines-text ($kept | append $"WATCHDOG_MODULE=($WATCHDOG_MODULE)"))) {
        print $">>> Proxmox: watchdog-mux arms the ($WATCHDOG_MODULE) hardware watchdog from the next host boot"
    }
    let active = watchdogs-active $host.watchdog_class_dir
    if $WATCHDOG_IDENTITY not-in $active {
        warn ([
            $"watchdog-mux feeds ($active | str join ', ' | default --empty none), not the ($WATCHDOG_IDENTITY): a hard hang"
            "waits for a power cycle until the host reboots, or until: systemctl stop watchdog-mux && rmmod softdog &&"
            "systemctl start watchdog-mux"
        ] | str join " ")
    }
}

# the identity of every watchdog device something holds open
def watchdogs-active [class_dir: path]: nothing -> list<string> {
    glob ($class_dir | path join *) | where { (open --raw ($in | path join state) | str trim) == "active" }
        | each { open --raw ($in | path join identity) | str trim }
}

# root logs in with its keys alone; the console stays the way back in
export def sshd-converge [host: record]: nothing -> nothing {
    if not (file-converge $host.sshd_dropin "644" (lines-text $SSHD_KEYS_ONLY)) { return }
    # sshd refusing its config would lock out the next login, not this one
    if not (succeeds [sshd -t]) {
        rm --force $host.sshd_dropin
        fail "sshd refuses its config with the keys-only drop-in, which is removed again."
    }
    let effective = ^sshd -T | lines
    if "passwordauthentication no" not-in $effective {
        fail $"sshd does not read ($host.sshd_dropin): its sshd_config includes no sshd_config.d."
    }
    ^systemctl reload ssh
    print ">>> Proxmox: root logs in over ssh with its keys alone"
}

# root takes exactly the lab's root keys plus the node's own, which pve uses to reach itself
def root-converge [host: record]: nothing -> nothing {
    $"root:($host.root_password)\n" | ^chpasswd
    let keys_file = "/root/.ssh/authorized_keys" | path expand
    let node_keys = open --raw $keys_file | lines | where { str ends-with $" root@(node-name)" }
    let wanted = lines-text ($node_keys ++ $host.root_keys)
    # in place: the file is pmxcfs' (/etc/pve/priv), a rename across its link would break the link
    if (open --raw $keys_file) != $wanted { $wanted | save --force $keys_file }
    sshd-converge $host
}

# the lab's subnets through its router, so the host answers a guest at the guest's own address: the router leaves
# traffic to the host unmasqueraded, and the host firewall admits by that address (terraform/lib.tf)
export def lab-route-converge [host: record]: nothing -> nothing {
    let routes = $host.lab_subnets | each { $"($in) via ($host.router_ip)" }
    let unit = lines-text ([
        "[Unit]" "Description=Route the lab's subnets through its router" "After=network-online.target"
        "Wants=network-online.target"
        "[Service]" "Type=oneshot" "RemainAfterExit=yes"
    ] ++ ($routes | each { $"ExecStart=/usr/sbin/ip route replace ($in)" })
      ++ ($routes | each { $"ExecStop=-/usr/sbin/ip route del ($in)" })
      ++ ["[Install]" "WantedBy=multi-user.target"])
    if not (file-converge $host.lab_route_unit "644" $unit) { return }
    let name = $host.lab_route_unit | path basename
    ^systemctl daemon-reload
    ^systemctl enable $name
    ^systemctl restart $name
    print $">>> Proxmox: the lab's subnets route through ($host.router_ip)"
}

# proxmox-firewall enforces the rules through nftables, whose guest chains sync.nu reads back
export def firewall-backend-converge []: nothing -> nothing {
    let options = $"/nodes/(node-name)/firewall/options"
    if (pve-json pvesh get $options | get --optional nftables) == 1 { return }
    ^pvesh set $options --nftables 1
    print ">>> Proxmox: the host firewall runs on nftables (proxmox-firewall)"
}

def users-converge [host: record]: nothing -> nothing {
    let declared = [terraform-prov@pve homepage@pve] ++ ($host.wake_zones | each { $"wake-($in)@pve" })

    # token only, like every lab user: a password would be unused
    if not (pve-user-exists terraform-prov@pve) { ^pveum user add terraform-prov@pve }
    ^pveum acl modify / --users terraform-prov@pve --roles Administrator
    token-ensure $host terraform terraform-prov@pve terraform-token --privsep 0

    # the homepage widget reads, nothing more
    if not (pve-user-exists homepage@pve) { ^pveum user add homepage@pve }
    ^pveum acl modify / --users homepage@pve --roles PVEAuditor
    token-ensure $host homepage homepage@pve homepage --privsep 0

    # a privsep token gets what both it and its user are granted: terraform grants both each onDemand guest
    if (pve-has (pve-json pveum role list) roleid $WAKE_ROLE) {
        ^pveum role modify $WAKE_ROLE --privs $WAKE_PRIVILEGES
    } else {
        ^pveum role add $WAKE_ROLE --privs $WAKE_PRIVILEGES
    }
    for zone in $host.wake_zones {
        let user = $"wake-($zone)@pve"
        if not (pve-user-exists $user) { ^pveum user add $user --comment $"on-demand wake, ($zone) ingress" }
        token-ensure $host $"wake-($zone)" $user ondemand --privsep 1 --comment $"($zone) ingress on-demand"
    }

    let users = pve-json pveum user list | get userid | where { str ends-with "@pve" }
    for user in ($users | where $it not-in $declared) {
        ^pveum user delete $user
        print $">>> Proxmox: removed ($user), no lab user"
    }
    # the lab declares no pool: terraform grants per guest, since the provider recreates a container whose pool changes
    for pool in (pve-json pveum pool list | get --optional poolid | default []) {
        # proxmox refuses a pool that still holds guests or storage: someone's own, kept
        if (succeeds [pveum pool delete $pool]) {
            print $">>> Proxmox: removed pool ($pool)"
        } else {
            print $">>> Proxmox: kept pool ($pool), it is not empty"
        }
    }
}

# lldap over ldaps verified against its own certificate, a totp code on top of the password, and a sync job proxmox
# runs itself. Fails closed: until the guest holds a certificate (its first deploy, the run after this one), the
# realm's group administers nothing.
export def realm-converge [host: record]: nothing -> nothing {
    let ldap = $host.lldap
    let group = $"($ldap.admin_group)-($REALM)"
    let ca = guest-file-read ($ldap.vmid | into string) $ldap.cert | str trim --right --char "\n"
    if $CERT_BEGIN not-in ($ca | lines) {
        let granted = pve-json pveum acl list | any { $in.ugid? == $group and $in.path? == "/" }
        if $granted { ^pveum acl delete / --groups $group --roles Administrator }
        warn $"vm-($ldap.vmid) holds no ldaps certificate yet \(($ldap.cert)\): ($group) administers nothing until a sync reads it"
        return
    }
    ^install -d -m 700 ($host.realm_ca_file | path dirname)
    file-converge $host.realm_password_file "600" $ldap.bind_password | ignore
    file-converge $host.realm_ca_file "600" $"($ca)\n" | ignore
    # the type is fixed at creation, modify refuses it
    let mode = if (pve-has (pve-json pveum realm list) realm $REALM) { [modify $REALM] } else { [add $REALM --type ldap] }
    (^pveum realm ...$mode
        --server1 $ldap.host --port ($ldap.port | into string) --mode ldaps --verify 1 --capath $host.realm_ca_file
        --base_dn $"ou=people,($ldap.base_dn)" --user_attr uid --bind_dn $"uid=($ldap.bind_user),ou=people,($ldap.base_dn)"
        --group_dn $"ou=groups,($ldap.base_dn)" --group_name_attr cn --group_classes groupOfUniqueNames
        --sync-defaults-options "enable-new=1,scope=both" --tfa $REALM_TFA --comment "lldap (single sign-on account store)")
    # the sync fills the group it would create; it exists before the first sync so the acl can name it
    if not (pve-has (pve-json pveum group list) groupid $group) { ^pveum group add $group }
    ^pveum acl modify / --groups $group --roles Administrator
    let job = [--schedule $REALM_SYNC_SCHEDULE --scope both --enable-new 1 --enabled 1]
    if (pve-has (pve-json pvesh get /cluster/jobs/realm-sync) id $REALM) {
        ^pvesh set $"/cluster/jobs/realm-sync/($REALM)" ...$job out> /dev/null
    } else {
        ^pvesh create $"/cluster/jobs/realm-sync/($REALM)" --realm $REALM ...$job out> /dev/null
    }
}

# the node's name resolves to its lan address: the installer wrote the address of its day, and pvecm updatecerts
# signs whatever the name resolves to
def node-address []: nothing -> string {
    let resolved = do { ^getent ahostsv4 (node-name) } | complete
    $resolved.stdout | lines | get --optional 0 | default "" | split row " " | first
}

export def hosts-converge [host: record]: nothing -> nothing {
    let ip = $host.proxmox_ip
    let node = node-name
    let before = node-address
    if $before == $ip { return }
    if ($host.corosync_conf | path exists) {
        fail $"($node) resolves to ($before), not ($ip), in a cluster: fix its address by hand."
    }
    let addresses = ^ip -o -4 addr show
    if not ($addresses | str contains $" inet ($ip)/") { fail $"no interface of this host holds ($ip) \(site.json lan.proxmox\)." }
    ^sed -i -E ($"/[[:space:]]($node)" + '([[:space:]]|$)/ s/^[0-9.]+/' + $"($ip)/") $host.hosts_file
    if (node-address) != $ip { fail $"($node) does not resolve to ($ip): give it a line in ($host.hosts_file)." }
    # pmxcfs resolves the node's address once, at its start; restarted, it reports the one pvecm signs below
    ^systemctl restart pve-cluster
    print $">>> Proxmox: ($host.hosts_file) names ($node) at ($ip)"
}

# clients verify the api against the cluster CA (site.json proxmoxCa) and by address: the node certificate must name
# the host's address, which the installer's certificate misses once the address changed. Re-signing keeps the CA.
def api-cert-names-ip [host: record]: nothing -> bool {
    let names = ^openssl x509 -in $host.api_cert -noout -ext subjectAltName
    $names | lines | each { split row "," } | flatten | str trim | any { $in == $"IP Address:($host.proxmox_ip)" }
}

export def api-cert-converge [host: record]: nothing -> nothing {
    if ($host.api_custom_cert | path exists) {
        fail $"pveproxy serves ($host.api_custom_cert), which does not chain to proxmoxCa: remove it \(pvenode cert delete\)."
    }
    if (api-cert-names-ip $host) { return }
    print $">>> Proxmox: the api certificate does not name ($host.proxmox_ip), re-signing it"
    ^pvecm updatecerts --force out> /dev/null
    ^systemctl restart pveproxy
    if not (api-cert-names-ip $host) { fail $"the re-signed ($host.api_cert) still does not name ($host.proxmox_ip)." }
}

# pvestatd's lvm.conf, rejecting every name of the bulk pv; written whole, never an edit of the host's lvm.conf, whose
# layout pve-manager owns
def pvestatd-lvm-render [names: list<string>]: nothing -> string {
    let rejects = $PVE_LVM_REJECTS ++ ($names | each { $"r|^($in)$|" }) | each { $"\"($in)\"" } | str join ", "
    lines-text [
        "# scripts/pve-install.nu: pvestatd's lvm view, which never reads the bulk disk"
        "devices {"
        $"  global_filter = [ ($rejects) ]"
        "}"
    ]
}

# lvm under that config reads a filter rejecting the pv, still sees the pve group and sees no bulk pv
def pvestatd-lvm-check [dir: path, pv: string]: nothing -> nothing {
    with-env {LVM_SYSTEM_DIR: $dir} {
        let filter = do { ^lvmconfig devices/global_filter } | complete
        if $filter.exit_code != 0 { fail $"lvm cannot read pvestatd's config ($dir)/lvm.conf." }
        if not ($filter.stdout | str contains $"\"r|^($pv)$|\"") {
            fail $"pvestatd's lvm filter does not reject ($pv): ($filter.stdout | str trim)"
        }
        let seen = ^pvs --noheadings -o vg_name
        let groups = $seen | lines | str trim
        if "pve" not-in $groups { fail "under pvestatd's lvm config the pve volume group is gone." }
        if "bulk" in $groups { fail "pvestatd's lvm config does not reject the bulk pv." }
    }
}

# disabled or not, pvestatd's lvm scans for local-lvm read every pv label, the hdd's too: it runs with its own lvm
# config, rebuilt from the bulk pv's names on every run and checked before it replaces the last one
export def pvestatd-lvm-converge [host: record]: nothing -> nothing {
    let listed = ^pvs --noheadings -o pv_name,vg_name
    let pv = $listed | lines | each { str trim | split row --regex '\s+' } | where { ($in | get --optional 1) == "bulk" } | get --optional 0.0
    if $pv == null { fail "the bulk volume group has no pv." }
    let target = $pv | path expand
    let aliases = ls --all $host.disk_by_id_dir | get name | sort | where { ($in | path expand) == $target }
    let dir = $host.pvestatd_lvm_dir
    let new = $"($dir).new"
    rm --recursive --force $new
    ^install -d -m 755 $new
    pvestatd-lvm-render ([$pv] ++ $aliases) | save --force ($new | path join lvm.conf)
    try { pvestatd-lvm-check $new $pv } catch {|e|
        rm --recursive --force $new
        error make $e
    }
    let installed = $dir | path join lvm.conf
    if ($installed | path exists) and (open --raw $installed) == (open --raw ($new | path join lvm.conf)) {
        rm --recursive --force $new
    } else {
        rm --recursive --force $dir
        mv $new $dir
    }
    ^install -d $host.pvestatd_dropin_dir
    let dropin = lines-text ["[Service]" $"Environment=LVM_SYSTEM_DIR=($dir)"]
    if (file-converge ($host.pvestatd_dropin_dir | path join homelab-no-hdd.conf) "644" $dropin) { unit-restart pvestatd }
}

def bulk-hook []: nothing -> string {
    nu-script '# proxmox runs it around the nas guest start and stop: bulk is enabled only while that changes
def main [vmid: string, phase: string] {
    let disable = match $phase { "pre-start" | "pre-stop" => "0", "post-start" | "post-stop" => "1", _ => null }
    # a failed toggle must not refuse the guest its start or stop
    if $disable != null { do { ^pvesm set bulk --disable $disable } | complete | ignore }
}
'
}

def bulk-converge [host: record]: nothing -> nothing {
    let bulk_exists = {|| succeeds [vgs bulk] }
    if ($host.bulk_disk | is-not-empty) and not (do $bulk_exists) {
        let disk = $host.bulk_disk
        if not (succeeds [test -b $disk]) { fail $"the bulk disk ($disk) is not present." }
        # never wipe a disk holding a filesystem
        let fstype = ^lsblk -no FSTYPE $disk
        if ($fstype | str trim | is-not-empty) { fail $"($disk) holds a filesystem; clear it by hand once its contents are safe." }
        ^pvcreate -ff -y $disk
        ^vgcreate bulk $disk
        ^lvcreate --type thin-pool -l $BULK_POOL_EXTENTS -Zn --thinpool data bulk
    }
    if not (do $bulk_exists) { return }
    if not (succeeds [pvesm status --storage bulk]) { ^pvesm add lvmthin bulk --vgname bulk --thinpool data --content images }

    let local = open --raw $STORAGE_CFG | lines | skip until { $in == "dir: local" } | first 4
    if not ($local | any { str contains snippets }) { ^pvesm set local --content backup,vztmpl,iso,snippets }
    ^install -d $SNIPPETS_DIR
    file-converge ($SNIPPETS_DIR | path join $BULK_HOOK_NAME) "755" (bulk-hook) | ignore
    # onboot start checks the storage before the hookscript runs, so host boot enables bulk for the autostart
    ^install -d ($PVE_GUESTS_DROPIN | path dirname)
    if (file-converge $PVE_GUESTS_DROPIN "644" (lines-text ["[Service]" "ExecStartPre=/usr/sbin/pvesm set bulk --disable 0"])) {
        ^systemctl daemon-reload
    }
    pvestatd-lvm-converge $host

    # terraform creates the nas guest after the first run; the run after it hooks the guest. A running guest keeps
    # the pool as its hookscript's pre-start left it until it stops.
    let nas = $host.nas_id | into string
    if not (succeeds [qm status $nas]) { return }
    let config = ^qm config $nas
    if $"hookscript: local:snippets/($BULK_HOOK_NAME)" not-in ($config | lines) {
        ^qm set $nas --hookscript $"local:snippets/($BULK_HOOK_NAME)" out> /dev/null
    }
    let status = ^qm status $nas
    if ($status | str trim | split row " " | get --optional 1) == "running" { ^pvesm set bulk --disable 1 }
}

# fill of every thin pool on this host, for node_exporter's textfile collector
def thinpool-metrics []: nothing -> string {
    nu-script '# fill of every thin pool on this host, for node_exporter textfile collector
def main [] {
    # lvm localizes the decimal separator; prometheus wants a dot
    let pools = with-env {LC_ALL: C} {
        ^lvs --noheadings --nosuffix --units b --separator "|" --select "segtype=thin-pool" -o vg_name,lv_name,lv_size,data_percent,metadata_percent
    }
    let rows = $pools | lines | each { split row "|" | str trim } | where { ($in | length) == 5 and $in.0 != "" }
    let gauges = $rows | each {|r|
        let labels = $"vg=\"($r.0)\",lv=\"($r.1)\""
        [$"homelab_thinpool_size_bytes{($labels)} ($r.2)" $"homelab_thinpool_data_percent{($labels)} ($r.3)" $"homelab_thinpool_metadata_percent{($labels)} ($r.4)"]
    } | flatten
    let text = [
        "# HELP homelab_thinpool_size_bytes Size of an LVM thin pool."
        "# TYPE homelab_thinpool_size_bytes gauge"
        "# HELP homelab_thinpool_data_percent Data space used in an LVM thin pool."
        "# TYPE homelab_thinpool_data_percent gauge"
        "# HELP homelab_thinpool_metadata_percent Metadata space used in an LVM thin pool."
        "# TYPE homelab_thinpool_metadata_percent gauge"
    ] ++ $gauges | each { $"($in)\n" } | str join
    let file = $env.TEXTFILE_DIR | path join thinpool.prom
    $text | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}
'
}

# run by smartd on a warning, which it describes in SMARTD_DEVICE, SMARTD_FAILTYPE and SMARTD_MESSAGE
export def smartd-textfile []: nothing -> string {
    nu-script ('# one file per device and kind of failure, the warning itself in the message label
def main [...args: string] {
    let device = $env.SMARTD_DEVICE
    let type = $env.SMARTD_FAILTYPE
    let message = $env.SMARTD_MESSAGE? | default "" | lines | get --optional 0 | default "" | str trim
        | str replace --all "\\" "\\\\" | str replace --all "\"" "\\\""
    let name = $"($device)-($type)" | str replace --all --regex "[^A-Za-z0-9]" "_"
    let file = "TEXTFILE_DIR" | path join $"smartd-($name).prom"
    [
        "# HELP homelab_smartd_warning_timestamp_seconds When smartd last warned about a disk."
        "# TYPE homelab_smartd_warning_timestamp_seconds gauge"
        $"homelab_smartd_warning_timestamp_seconds{device=\"($device)\",type=\"($type)\",message=\"($message)\"} (date now | format date %s)"
    ] | each { $"($in)\n" } | str join | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}
' | str replace TEXTFILE_DIR $TEXTFILE_DIR)
}

# the nvme collector reports neither the drives' thermal management time nor the machine checks
export def hardware-metrics []: nothing -> string {
    nu-script '# the throttled and over-temperature time of every nvme namespace, and the machine checks of this boot
def main [] {
    let listed = ^nvme list --output-format json | from json
    let drives = $listed.Devices | get DevicePath | sort | each {|path|
        let log = ^nvme smart-log $path --output-format json | from json
        let labels = $"device=\"($path | path basename)\""
        [
            $"homelab_nvme_thermal_throttle_seconds_total{($labels)} ($log.thm_temp1_total_time + $log.thm_temp2_total_time)"
            $"homelab_nvme_warning_temperature_seconds_total{($labels)} ($log.warning_temp_time * 60)"
        ]
    } | flatten
    # journalctl exits 1 when no line matches
    let found = do { ^journalctl -k -b -q -o cat --grep "\\[Hardware Error\\]" } | complete
    let text = [
        "# HELP homelab_nvme_thermal_throttle_seconds_total Time the drive throttled itself for heat."
        "# TYPE homelab_nvme_thermal_throttle_seconds_total counter"
        "# HELP homelab_nvme_warning_temperature_seconds_total Time the drive ran above its warning temperature."
        "# TYPE homelab_nvme_warning_temperature_seconds_total counter"
        ...$drives
        "# HELP homelab_mce_events_total Kernel hardware error lines since this boot."
        "# TYPE homelab_mce_events_total gauge"
        $"homelab_mce_events_total ($found.stdout | lines | length)"
    ] | each { $"($in)\n" } | str join
    let file = $env.TEXTFILE_DIR | path join hardware.prom
    $text | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}
'
}

def ossec-metrics [ossec_dir: path]: nothing -> string {
    nu-script ('# today ossec alerts by severity (7+ notable, 10+ urgent)
def main [] {
    let log = "OSSEC_DIR/logs/alerts/alerts.log"
    let alerts = if ($log | path exists) { open --raw $log | lines } else { [] }
    let total = $alerts | where { str starts-with "** Alert" } | length
    let high = $alerts | where $it =~ "Level: (1[0-9]|[7-9])" | length
    let up = if (do { ^pgrep -x ossec-analysisd } | complete).exit_code == 0 { 1 } else { 0 }
    let text = [
        "# HELP homelab_ossec_alerts_total OSSEC alerts on the hypervisor."
        "# TYPE homelab_ossec_alerts_total gauge"
        $"homelab_ossec_alerts_total ($total)"
        "# HELP homelab_ossec_alerts_high OSSEC alerts at level 7 or above."
        "# TYPE homelab_ossec_alerts_high gauge"
        $"homelab_ossec_alerts_high ($high)"
        "# HELP homelab_ossec_up Whether ossec-analysisd is running."
        "# TYPE homelab_ossec_up gauge"
        $"homelab_ossec_up ($up)"
    ] | each { $"($in)\n" } | str join
    let file = $env.TEXTFILE_DIR | path join ossec.prom
    $text | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}
' | str replace OSSEC_DIR $ossec_dir)
}

def exporter-converge []: nothing -> nothing {
    ^install -d -m 0755 $TEXTFILE_DIR
    # the watchdog collector shows which watchdog mux feeds (node_watchdog_info), which vm-103 alerts on
    let args = $"--collector.textfile.directory=($TEXTFILE_DIR) --collector.watchdog"
    if (file-converge /etc/default/prometheus-node-exporter "644" $"ARGS=\"($args)\"\n") {
        ^systemctl restart prometheus-node-exporter
    }
    ^systemctl -q enable --now prometheus-node-exporter
    # apt: pending upgrades by origin, the security ones among them
    for collector in [apt smartmon nvme] { ^systemctl -q enable --now $"prometheus-node-exporter-($collector).timer" }

    # guests overprovision local-lvm (pve/data) and bulk/data; a full thin pool pauses every guest on it, and
    # node_exporter has no lvm collector, so lvs feeds gauges that vm-103 alerts on
    textfile-job-install thinpool-metrics "LVM thin pool fill" 1m (thinpool-metrics)

    # smartd's warnings become a gauge vm-103 alerts on, instead of mail to a root mailbox nobody reads
    file-converge /usr/local/bin/smartd-textfile "755" (smartd-textfile) | ignore
    # repeated daily while it lasts, which keeps the gauge fresh for vm-103's smartd_warning rule
    let smartd = "DEVICESCAN -d removable -n standby -m root -M daily -M exec /usr/local/bin/smartd-textfile\n"
    if (file-converge /etc/smartd.conf "644" $smartd) { ^systemctl restart smartd }
    # machine-check and memory errors land in rasdaemon's database and the journal
    ^systemctl -q enable --now rasdaemon
    textfile-job-install hardware-metrics "nvme thermal time and machine checks" 1m (hardware-metrics)
}

# the host's journal to vm-103's journal-remote, as every guest's goes: its logins, kernel and hang evidence reach loki
export def journal-upload-converge [host: record]: nothing -> nothing {
    ^install -d ($host.journal_upload_dropin | path dirname)
    if (file-converge $host.journal_upload_dropin "644" (lines-text ["[Upload]" $"URL=($host.journal_upload)"])) {
        ^systemctl restart systemd-journal-upload
    }
    ^systemctl -q enable --now systemd-journal-upload
}

# the source archive, checked against the pinned hash before anything of it runs as root; false when github or the
# mirrors do not answer
def ossec-fetch [dir: path]: nothing -> bool {
    if not (packages-install $OSSEC_BUILD_PACKAGES) { return false }
    let archive = $dir | path join ossec.tar.gz
    if not (succeeds [wget -q $"--timeout=($DOWNLOAD_TIMEOUT_S)" $"--tries=($DOWNLOAD_TRIES)" -O $archive $OSSEC_URL]) { return false }
    if (open --raw $archive | hash sha256) != $OSSEC_SHA256 {
        fail $"the OSSEC ($OSSEC_VERSION) archive does not match its pinned sha256."
    }
    true
}

# host intrusion detection, built from the pinned source; the binary marks a finished install, so a half one from an
# interrupted run is removed and built again. The install prefix is compiled in, so it cannot be staged elsewhere.
export def ossec-converge [host: record]: nothing -> nothing {
    let dir = $host.ossec_dir
    let control = $dir | path join bin ossec-control
    if not ($control | path exists) {
        print $">>> Proxmox: building OSSEC ($OSSEC_VERSION)"
        rm --recursive --force $dir
        let tmp = mktemp --directory --tmpdir
        let fetched = try { ossec-fetch $tmp } catch {|e|
            rm --recursive --force $tmp
            error make $e
        }
        if not $fetched {
            rm --recursive --force $tmp
            warn "github or the package mirrors are unavailable: OSSEC is not installed, the next run retries."
            return
        }
        ^tar -xzf ($tmp | path join ossec.tar.gz) -C $tmp
        # install.sh is interactive; USER_* answers it
        let answers = {
            USER_LANGUAGE: en, USER_NO_STOP: y, USER_INSTALL_TYPE: local, USER_DIR: $dir, USER_ENABLE_ACTIVE_RESPONSE: n
            USER_ENABLE_SYSCHECK: y, USER_ENABLE_ROOTCHECK: y, USER_ENABLE_EMAIL: n, USER_ENABLE_SYSLOG: y
        }
        do {
            cd ($tmp | path join $"ossec-hids-($OSSEC_VERSION)")
            with-env $answers { "" | ^./install.sh }
        }
        rm --recursive --force $tmp
    }

    # realtime where the kernel supports it
    file-converge ($dir | path join etc local_internal_options.conf) "644" "syscheck.sleep=2\n" | ignore
    let conf = $dir | path join etc ossec.conf
    let text = open --raw $conf
    if not ($text | str contains $OSSEC_MANAGED_MARK) {
        $text | str replace --all $OSSEC_FREQUENCY_DEFAULT $OSSEC_FREQUENCY | str replace "</ossec_config>" $"($OSSEC_WATCH)</ossec_config>"
            | save --force $conf
    }
    # the source install ships no unit: without one ossec would not come back after a host reboot
    if (file-converge /etc/systemd/system/ossec.service "644" (lines-text [
        "[Unit]" "Description=OSSEC host intrusion detection" "After=network-online.target" ""
        "[Service]" "Type=oneshot" "RemainAfterExit=yes" $"ExecStart=($control) start" $"ExecStop=($control) stop" ""
        "[Install]" "WantedBy=multi-user.target"
    ])) {
        ^systemctl daemon-reload
    }
    ^systemctl -q enable --now ossec
    textfile-job-install ossec-metrics "OSSEC alert counts" 5m (ossec-metrics $dir)
}

def converge [host: record]: nothing -> nothing {
    let required = [proxmox_ip router_ip lab_subnets zone_bridges wake_zones nas_id journal_upload root_password root_keys lldap]
    let absent = $required | where {|k| ($host | get --optional $k | default "" | is-empty) }
    if ($absent | is-not-empty) { fail $"converge needs ($absent | str join ', ')" }
    let ldap_absent = [vmid host port base_dn admin_group cert bind_user bind_password]
        | where {|k| ($host.lldap | get --optional $k | default "" | into string | is-empty) }
    if ($ldap_absent | is-not-empty) { fail $"converge needs lldap's ($ldap_absent | str join ', ')" }
    apt-sources-converge
    bridges-converge $host
    gpu-converge $host
    power-converge
    ipmi-converge $host
    recovery-converge $host
    root-converge $host
    lab-route-converge $host
    firewall-backend-converge
    users-converge $host
    realm-converge $host
    hosts-converge $host
    api-cert-converge $host
    bulk-converge $host
    if (packages-install $PACKAGES) {
        exporter-converge
        journal-upload-converge $host
    } else {
        warn "the package mirrors are unavailable: the host exporter, rasdaemon and the journal upload wait for the next run."
    }
    ossec-converge $host
    let version = ^pveversion
    print $">>> Proxmox ($version | str trim) converged."
}

def kernel-newest [boot_dir: path]: nothing -> string {
    glob ($boot_dir | path join "vmlinuz-*") | path basename | str replace "vmlinuz-" "" | sort --natural | last
}

# every package to its newest version; the new kernel and microcode wait for the host's next boot
export def upgrade [host: record]: nothing -> nothing {
    with-env {DEBIAN_FRONTEND: noninteractive} {
        if not (succeeds [apt-get ...$APT_OPTIONS update]) { fail "the package mirrors are unavailable: nothing upgraded." }
        "" | ^apt-get ...$APT_OPTIONS ...$APT_KEEP_CONFIG full-upgrade -y
    }
    let running = ^uname -r | str trim
    let newest = kernel-newest $host.boot_dir
    if $newest == $running {
        print $">>> Proxmox upgraded, still on its newest kernel ($running)."
    } else {
        print $">>> Proxmox upgraded: REBOOT the host to run kernel ($newest) instead of ($running), and the new microcode."
    }
}

def guest-ids [kind: string]: nothing -> list<string> {
    let listed = ^$kind list
    $listed | lines | skip 1 | str trim | where $it != "" | each { split row --regex '\s+' | first }
}

def guest-running [kind: string, id: string]: nothing -> bool {
    let status = ^$kind status $id
    ($status | str trim | split row " " | get --optional 1) == "running"
}

# every guest and what converge and terraform made on the host, except what it keeps working without the lab: OSSEC,
# the bulk pool, gpu passthrough, apt sources, root's password, keys and ssh settings, the node's address and
# certificate, the firewall backend, the power, recovery, module and smartd settings. The datacenter firewall goes off
# with its rules, which a fresh terraform state would add a second time.
export def teardown [host: record]: nothing -> nothing {
    for id in (guest-ids qm) {
        if (guest-running qm $id) { ^qm stop $id --skiplock 1 out> /dev/null }
        ^qm destroy $id --destroy-unreferenced-disks 1 --purge 1 out> /dev/null
    }
    for id in (guest-ids pct) {
        if (guest-running pct $id) { ^pct stop $id out> /dev/null }
        ^pct destroy $id --purge 1 --destroy-unreferenced-disks 1 out> /dev/null
    }
    for template in $host.templates { rm --force $template }
    rm --recursive --force $host.token_dir

    ^pvesh set /cluster/firewall/options --enable 0
    for pos in (pve-json pvesh get /cluster/firewall/rules | get --optional pos | default [] | sort --reverse) {
        ^pvesh delete $"/cluster/firewall/rules/($pos)"
    }

    # deleting a user deletes its tokens and acl entries
    for user in (pve-json pveum user list | get --optional userid | default [] | where { str ends-with "@pve" }) { ^pveum user delete $user }
    for pool in (pve-json pveum pool list | get --optional poolid | default []) { ^pveum pool delete $pool }
    if (pve-has (pve-json pveum role list) roleid $WAKE_ROLE) { ^pveum role delete $WAKE_ROLE }
    if (pve-has (pve-json pvesh get /cluster/jobs/realm-sync) id $REALM) { ^pvesh delete $"/cluster/jobs/realm-sync/($REALM)" }
    if (pve-has (pve-json pveum realm list) realm $REALM) { ^pveum realm delete $REALM }
    for group in (pve-json pveum group list | get --optional groupid | default [] | where { str ends-with $"-($REALM)" }) {
        ^pveum group delete $group
    }
    rm --force $host.realm_password_file $host.realm_ca_file

    if ($host.lab_route_unit | path exists) {
        ^systemctl disable --now ($host.lab_route_unit | path basename)
        rm --force $host.lab_route_unit
    }

    with-env {DEBIAN_FRONTEND: noninteractive} {
        "" | ^apt-get purge -y prometheus-node-exporter out> /dev/null
        "" | ^apt-get autoremove -y out> /dev/null
    }

    for bridge in (bridges-present $host.network_interfaces) { bridge-remove $host.network_interfaces $bridge }
    ^ifreload -a
    print $">>> Proxmox: torn down; left: (guest-ids qm | length) vms, (guest-ids pct | length) containers"
}

def main [action: string]: string -> nothing {
    let inputs = $in | from json
    let host = pve-host | merge $inputs
    try {
        if (which pveversion | is-empty) { fail "install Proxmox VE first, then rerun init.nu." }
        match $action {
            "converge" => { converge $host }
            "upgrade" => { upgrade $host }
            "teardown" => { teardown $host }
            _ => { fail $"the action is converge, upgrade or teardown, not ($action)" }
        }
    } catch {|e|
        print -e $"ERROR: ($e.msg)"
        exit 1
    }
}
