#!/usr/bin/env bash
# converge the Proxmox VE host to what the lab declares; every run of init.sh and sync.sh runs it, reruns change
# nothing
#
# lib/proxmox.sh (proxmox_converge) prepends its inputs on stdin, out of argv:
#   PROXMOX_IP            the host's lan address (site.json), which its api certificate must name
#   ZONE_BRIDGES          every zone's bridge (zones.json); vmbr0 comes from the installer
#   WAKE_ZONES            the zones whose ingress wakes onDemand guests (terraform/lib.tf grants each its guests)
#   GPU_IDS               the passthrough gpu's functions (site.json), empty for none
#   BULK_DISK             the disk the bulk pool is created on; init.sh asks it once, empty keeps the pool as it is
#   NAS_ID                the nas guest, whose hookscript wakes the bulk pool around its start and stop
#   LLDAP_HOST LLDAP_PORT LLDAP_BASE_DN LLDAP_CA   lldap's ldaps listener and the CA its certificate chains to
#   LLDAP_BIND_PASSWORD   lldap's read-only proxmox-bind user
#   ROOT_PASSWORD         root@pam's own password (proxmox-root-pass)
#   ROOT_KEYS             the ssh keys root takes, one per line
# An api token is created only when missing, its secret written once to TOKEN_DIR/<role> as "<token id>=<secret>"
# for lib/proxmox.sh to store and delete; an existing token is never rotated.
#
# The lab owns the host: the pve realm's users, the pools, the bridges past vmbr0 and the roles are exactly the
# declared ones, so leftovers of earlier layouts go on the next run. The body is one function, parsed whole before
# it runs: the script arrives on stdin, and a command reading stdin must not eat the rest of it.
set -euo pipefail

: "${PROXMOX_IP:?}" "${ZONE_BRIDGES:?}" "${WAKE_ZONES:?}" "${NAS_ID:?}" "${ROOT_PASSWORD:?}" "${ROOT_KEYS:?}"
: "${LLDAP_HOST:?}" "${LLDAP_PORT:?}" "${LLDAP_BASE_DN:?}" "${LLDAP_CA:?}" "${LLDAP_BIND_PASSWORD:?}"
GPU_IDS="${GPU_IDS:-}"
BULK_DISK="${BULK_DISK:-}"

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------
TOKEN_DIR=/root/homelab-tokens
PACKAGES=(prometheus-node-exporter prometheus-node-exporter-collectors smartmontools nvme-cli jq)
OSSEC_BUILD_PACKAGES=(build-essential libevent-dev libpcre2-dev libz-dev libssl-dev libsystemd-dev wget ca-certificates)
# debian's textfile directory: its collector timers write there, and so do the gauges below
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
TEXTFILE_INTERVAL_MIN=5
# hdparm -S units of 5 s: 10 minutes
HDD_SPINDOWN_SETTING=120
# containers cannot load kernel modules: nfs for the privileged ones' mounts, overlay and br_netfilter for podman
LXC_MODULES=(nfs nfsv4 overlay br_netfilter)
WAKE_ROLE=HomelabWake
WAKE_PRIVILEGES=VM.Audit,VM.PowerMgmt
REALM=lldap
REALM_PASSWORD_FILE=/etc/pve/priv/realm/$REALM.pw
REALM_CA_FILE=/etc/pve/priv/realm/$REALM-ca.pem
# read-only (lldap_strict_readonly): the realm sync reads users and groups and never writes
REALM_BIND_USER=proxmox-bind
# the lldap group granted datacentre admin; the realm sync names it <group>-<realm>
REALM_ADMIN_GROUP=admins
REALM_SYNC_SCHEDULE=hourly
# a realm login asks for a totp code too; root@pam sets each user's key (README, "Proxmox login")
REALM_TFA=type=oath
API_CERT=/etc/pve/local/pve-ssl.pem
# bulk (hdd) stays disabled in proxmox: pvestatd polls enabled storages every 10s, which keeps the disk spinning;
# the nas guest's hookscript enables it only around its own start and stop
BULK_HOOK_NAME=homelab-bulk.sh
BULK_HOOK=/var/lib/vz/snippets/$BULK_HOOK_NAME
# of the bulk disk, the thin pool takes this much; the rest keeps full thin metadata from wedging the pool
BULK_POOL_EXTENTS=99%FREE
OSSEC_VERSION=3.8.0
# sha256 of github's source archive of that tag, checked before anything of it runs as root
OSSEC_SHA256=bd857a2dd7d0559ef59b4a9ec276f3a8ade6830f8aed257e8f4a62106cfe5f38
OSSEC_DIR=/var/ossec
OSSEC_CONTROL=$OSSEC_DIR/bin/ossec-control

# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------

# file_converge <path> <mode> [command...]: stdin becomes <path>; the command runs when that changed the file
file_converge() {
  local path=$1 mode=$2 new
  shift 2
  new=$(mktemp "$path.XXXXXX")
  cat > "$new"
  chmod "$mode" "$new"
  if cmp -s "$new" "$path"; then rm -f "$new"; return 0; fi
  mv "$new" "$path"
  [ "$#" = 0 ] || "$@"
}

# pveum and pvesh print json lists; jq reads them whole (grep -q closing the pipe early would fail under pipefail)
json_has() { jq -e --arg v "$2" ".[] | select(.$1 == \$v)" >/dev/null; }
pve_user_exists() { pveum user list --output-format json | json_has userid "$1"; }

# token_ensure <role> <user> <token> <pveum token add options...>
token_ensure() {
  local role=$1 user=$2 token=$3 secret
  shift 3
  pveum user token list "$user" --output-format json | json_has tokenid "$token" && return 0
  secret=$(pveum user token add "$user" "$token" "$@" --output-format json | jq -r '.value // empty')
  [ -n "$secret" ] || { echo "ERROR: Proxmox did not create the api token $user!$token." >&2; exit 1; }
  (umask 077; install -d "$TOKEN_DIR"; printf '%s=%s\n' "$user!$token" "$secret" > "$TOKEN_DIR/$role")
  echo ">>> Proxmox: created the api token $user!$token"
}

# textfile_job_install <name> <what it publishes> <first run after boot>: the script on stdin becomes
# /usr/local/bin/<name>, run every TEXTFILE_INTERVAL_MIN by a timer with TEXTFILE_DIR in its environment
textfile_job_install() {
  local name=$1 what=$2 boot_delay=$3
  file_converge "/usr/local/bin/$name" 755 textfile_job_start "$name"
  file_converge "/etc/systemd/system/$name.service" 644 textfile_job_start "$name" <<UNIT
[Unit]
Description=Publish $what for node_exporter
[Service]
Type=oneshot
Environment=TEXTFILE_DIR=$TEXTFILE_DIR
ExecStart=/usr/local/bin/$name
UNIT
  file_converge "/etc/systemd/system/$name.timer" 644 textfile_job_start "$name" <<UNIT
[Unit]
Description=Publish $what every $TEXTFILE_INTERVAL_MIN minutes
[Timer]
OnBootSec=$boot_delay
OnUnitActiveSec=${TEXTFILE_INTERVAL_MIN}m
[Install]
WantedBy=timers.target
UNIT
}

# unit_restart <unit>: after its drop-in changed
unit_restart() {
  systemctl daemon-reload
  systemctl restart "$1"
}

# the first sample now, not one interval after a change
textfile_job_start() {
  systemctl daemon-reload
  systemctl enable --now "$1.timer"
  systemctl start "$1.service"
}

# -----------------------------------------------------------------------------
# HOST
# -----------------------------------------------------------------------------

apt_converge() {
  local codename missing=()
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  # enterprise repos need a paid subscription; grep fails once no file names them
  for file in $(grep -rl "enterprise.proxmox.com" /etc/apt/ || true); do
    if [[ "$file" == *.sources ]]; then mv "$file" "/root/$(basename "$file").disabled"
    else sed -i 's|^.*enterprise\.proxmox\.com.*|# &|g' "$file"; fi
  done
  echo "deb http://download.proxmox.com/debian/pve $codename pve-no-subscription" \
    | file_converge /etc/apt/sources.list.d/pve-no-subscription.list 644
  for p in "${PACKAGES[@]}"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$p"); done
  [ "${#missing[@]}" = 0 ] && return 0
  echo ">>> Proxmox: installing ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" </dev/null >/dev/null
}

bridges_converge() {
  local bridge changed=0 present
  for bridge in $ZONE_BRIDGES; do
    grep -q "^auto $bridge\$" /etc/network/interfaces && continue
    printf '\nauto %s\niface %s inet manual\n    bridge-ports none\n    bridge-stp off\n    bridge-fd 0\n' "$bridge" "$bridge" \
      >> /etc/network/interfaces
    changed=1
  done
  mapfile -t present < <(sed -n 's/^auto \(vmbr[1-9][0-9]*\)$/\1/p' /etc/network/interfaces)
  for bridge in "${present[@]}"; do
    [[ " $ZONE_BRIDGES " == *" $bridge "* ]] && continue
    # a guest still on it would lose its network: that guest is the drift to fix first
    [ -z "$(ls "/sys/class/net/$bridge/brif" 2>/dev/null)" ] \
      || { echo "ERROR: $bridge is no zone's bridge but guests are on it: $(ls "/sys/class/net/$bridge/brif")" >&2; exit 1; }
    sed -i "/^auto $bridge\$/,/^\$/d" /etc/network/interfaces
    echo ">>> Proxmox: removed $bridge, no zone's bridge"
    changed=1
  done
  [ "$changed" = 0 ] || ifreload -a
}

# the boot files changed: rebuilt now, bound at the next host boot
gpu_stage() {
  update-initramfs -u -k all >/dev/null
  update-grub >/dev/null
  echo ">>> Proxmox: gpu passthrough staged; REBOOT the host to bind vfio-pci."
}

# iommu on, the gpu's functions bound to vfio-pci instead of their drivers
gpu_converge() {
  local iommu
  [ -n "$GPU_IDS" ] || return 0
  iommu=$(grep -q GenuineIntel /proc/cpuinfo && echo intel_iommu || echo amd_iommu)
  grep -q "${iommu}=on" /etc/default/grub \
    || sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\\)\"/\\1 ${iommu}=on iommu=pt\"/" /etc/default/grub
  printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' | file_converge /etc/modules-load.d/vfio.conf 644 gpu_stage
  echo "options vfio-pci ids=${GPU_IDS}" | file_converge /etc/modprobe.d/vfio.conf 644 gpu_stage
  printf 'blacklist nouveau\nblacklist nvidia\nblacklist nvidiafb\nblacklist snd_hda_intel\n' \
    | file_converge /etc/modprobe.d/blacklist-gpu.conf 644 gpu_stage
}

# the udev rule covers disks appearing from now on; the ones present spin down now
hdd_spindown_start() {
  local d
  for d in /sys/block/sd*; do
    if [ "$(cat "$d/queue/rotational")" = 1 ]; then hdparm -q -S "$HDD_SPINDOWN_SETTING" "/dev/${d##*/}"; fi
  done
}

modules_load() {
  local m
  for m in "${LXC_MODULES[@]}"; do modprobe "$m"; done
}

# cpu biased to efficiency, hdds asleep when idle, the containers' kernel modules; now and at every host boot
power_converge() {
  printf '%s\n' \
    "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave" \
    "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power" \
    | file_converge /etc/tmpfiles.d/homelab-power.conf 644 systemd-tmpfiles --create /etc/tmpfiles.d/homelab-power.conf
  echo "ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"sd[a-z]\", ATTR{queue/rotational}==\"1\", RUN+=\"/usr/sbin/hdparm -S $HDD_SPINDOWN_SETTING /dev/%k\"" \
    | file_converge /etc/udev/rules.d/69-homelab-hdd-spindown.rules 644 hdd_spindown_start
  printf '%s\n' "${LXC_MODULES[@]}" | file_converge /etc/modules-load.d/homelab-lxc.conf 644 modules_load
}

# root takes exactly the lab's root keys plus the node's own, which pve uses to reach itself
root_converge() {
  local keys_file
  printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
  keys_file=$(readlink -f /root/.ssh/authorized_keys)
  { grep " root@$(hostname)\$" "$keys_file"; printf '%s\n' "$ROOT_KEYS"; } > "$keys_file.new"
  # in place: the file is pmxcfs' (/etc/pve/priv), a rename across its link would break the link
  cmp -s "$keys_file.new" "$keys_file" || cat "$keys_file.new" > "$keys_file"
  rm -f "$keys_file.new"
}

# -----------------------------------------------------------------------------
# API ACCESS
# -----------------------------------------------------------------------------

users_converge() {
  local zone user declared=(terraform-prov@pve homepage@pve) pool
  for zone in $WAKE_ZONES; do declared+=("wake-$zone@pve"); done

  # token only, like every lab user: a password would be unused
  pve_user_exists terraform-prov@pve || pveum user add terraform-prov@pve
  pveum acl modify / --users terraform-prov@pve --roles Administrator
  token_ensure terraform terraform-prov@pve terraform-token --privsep 0

  # the homepage widget reads, nothing more
  pve_user_exists homepage@pve || pveum user add homepage@pve
  pveum acl modify / --users homepage@pve --roles PVEAuditor
  token_ensure homepage homepage@pve homepage --privsep 0

  # a privsep token gets what both it and its user are granted: terraform grants both each onDemand guest
  if pveum role list --output-format json | json_has roleid "$WAKE_ROLE"; then pveum role modify "$WAKE_ROLE" --privs "$WAKE_PRIVILEGES"
  else pveum role add "$WAKE_ROLE" --privs "$WAKE_PRIVILEGES"; fi
  for zone in $WAKE_ZONES; do
    pve_user_exists "wake-$zone@pve" || pveum user add "wake-$zone@pve" --comment "on-demand wake, $zone ingress"
    token_ensure "wake-$zone" "wake-$zone@pve" ondemand --privsep 1 --comment "$zone ingress on-demand"
  done

  for user in $(pveum user list --output-format json | jq -r '.[].userid | select(endswith("@pve"))'); do
    [[ " ${declared[*]} " == *" $user "* ]] && continue
    pveum user delete "$user"
    echo ">>> Proxmox: removed $user, no lab user"
  done
  # the lab declares no pool: terraform grants per guest, since the provider recreates a container whose pool changes
  for pool in $(pveum pool list --output-format json | jq -r '.[].poolid'); do
    pveum pool delete "$pool"
    echo ">>> Proxmox: removed pool $pool"
  done
}

# lldap over ldaps verified against its CA, a totp code on top of the password, and a sync job proxmox runs itself,
# so the realm needs no lldap at deploy time
realm_converge() {
  local mode=(add "$REALM" --type ldap) group="$REALM_ADMIN_GROUP-$REALM" job=()
  install -d -m 700 /etc/pve/priv/realm
  printf '%s' "$LLDAP_BIND_PASSWORD" | file_converge "$REALM_PASSWORD_FILE" 600
  printf '%s\n' "$LLDAP_CA" | file_converge "$REALM_CA_FILE" 600
  # the type is fixed at creation, modify refuses it
  pveum realm list --output-format json | json_has realm "$REALM" && mode=(modify "$REALM")
  pveum realm "${mode[@]}" \
    --server1 "$LLDAP_HOST" --port "$LLDAP_PORT" --mode ldaps --verify 1 --capath "$REALM_CA_FILE" \
    --base_dn "ou=people,$LLDAP_BASE_DN" --user_attr uid --bind_dn "uid=$REALM_BIND_USER,ou=people,$LLDAP_BASE_DN" \
    --group_dn "ou=groups,$LLDAP_BASE_DN" --group_name_attr cn --group_classes groupOfUniqueNames \
    --sync-defaults-options "enable-new=1,scope=both" --tfa "$REALM_TFA" --comment "lldap (single sign-on account store)"
  # the sync fills the group it would create; it exists before the first sync so the acl can name it
  pveum group list --output-format json | json_has groupid "$group" || pveum group add "$group"
  pveum acl modify / --groups "$group" --roles Administrator
  job=(--schedule "$REALM_SYNC_SCHEDULE" --scope both --enable-new 1 --enabled 1)
  if pvesh get /cluster/jobs/realm-sync --output-format json | json_has id "$REALM"; then
    pvesh set "/cluster/jobs/realm-sync/$REALM" "${job[@]}" >/dev/null
  else
    pvesh create "/cluster/jobs/realm-sync/$REALM" --realm "$REALM" "${job[@]}" >/dev/null
  fi
}

# clients verify the api against the cluster CA (site.json proxmoxCa) and by address: the node certificate must name
# the host's address, which the installer's certificate misses once the address changed. Re-signing keeps the CA.
api_cert_names_ip() {
  openssl x509 -in "$API_CERT" -noout -ext subjectAltName | tr ',' '\n' | sed 's/^ *//' | grep -qxF "IP Address:$PROXMOX_IP"
}

api_cert_converge() {
  api_cert_names_ip && return 0
  echo ">>> Proxmox: the api certificate does not name $PROXMOX_IP, re-signing it"
  pvecm updatecerts --force >/dev/null
  systemctl reload pveproxy
  api_cert_names_ip || { echo "ERROR: the re-signed $API_CERT still does not name $PROXMOX_IP: fix /etc/hosts." >&2; exit 1; }
}

# -----------------------------------------------------------------------------
# STORAGE
# -----------------------------------------------------------------------------

bulk_converge() {
  local pv rejects
  if [ -n "$BULK_DISK" ] && ! vgs bulk >/dev/null 2>&1; then
    [ -b "$BULK_DISK" ] || { echo "ERROR: the bulk disk $BULK_DISK is not present." >&2; exit 1; }
    # never wipe a disk holding a filesystem
    [ -z "$(lsblk -no FSTYPE "$BULK_DISK")" ] \
      || { echo "ERROR: $BULK_DISK holds a filesystem; clear it by hand once its contents are safe." >&2; exit 1; }
    pvcreate -ff -y "$BULK_DISK"
    vgcreate bulk "$BULK_DISK"
    lvcreate --type thin-pool -l "$BULK_POOL_EXTENTS" -Zn --thinpool data bulk
  fi
  vgs bulk >/dev/null 2>&1 || return 0
  pvesm status --storage bulk >/dev/null 2>&1 || pvesm add lvmthin bulk --vgname bulk --thinpool data --content images

  grep -A3 "^dir: local$" /etc/pve/storage.cfg | grep -q snippets || pvesm set local --content backup,vztmpl,iso,snippets
  install -d /var/lib/vz/snippets
  file_converge "$BULK_HOOK" 755 <<'HOOK'
#!/bin/sh
case "$2" in
  pre-start|pre-stop) pvesm set bulk --disable 0 ;;
  post-start|post-stop) pvesm set bulk --disable 1 ;;
esac
exit 0
HOOK
  # onboot start checks the storage before the hookscript runs, so host boot enables bulk for the autostart
  install -d /etc/systemd/system/pve-guests.service.d
  printf '[Service]\nExecStartPre=/usr/sbin/pvesm set bulk --disable 0\n' \
    | file_converge /etc/systemd/system/pve-guests.service.d/homelab-bulk.conf 644 systemctl daemon-reload
  # disabled or not, pvestatd's lvm scans for local-lvm read every pv label, the hdd's too: its own lvm config
  # rejects every name of the bulk pv, rebuilt from the real one each run
  pv=$(pvs --noheadings -o pv_name,vg_name | awk '$2 == "bulk" { print $1 }')
  rejects=$(for n in "$pv" /dev/disk/by-id/*; do
    if [ "$(readlink -f "$n")" = "$(readlink -f "$pv")" ]; then printf ',"r|^%s$|"' "$n"; fi
  done)
  rm -rf /etc/lvm-pvestatd.new && cp -a /etc/lvm /etc/lvm-pvestatd.new
  sed -i "s#^\(\s*global_filter=\[.*\)\]#\1$rejects]#" /etc/lvm-pvestatd.new/lvm.conf
  LVM_SYSTEM_DIR=/etc/lvm-pvestatd.new vgs pve >/dev/null
  rm -rf /etc/lvm-pvestatd && mv /etc/lvm-pvestatd.new /etc/lvm-pvestatd
  install -d /etc/systemd/system/pvestatd.service.d
  printf '[Service]\nEnvironment=LVM_SYSTEM_DIR=/etc/lvm-pvestatd\n' \
    | file_converge /etc/systemd/system/pvestatd.service.d/homelab-no-hdd.conf 644 unit_restart pvestatd

  # terraform creates the nas guest after the first run; the run after it hooks the guest. A running guest keeps
  # the pool as its hookscript's pre-start left it until it stops.
  qm status "$NAS_ID" >/dev/null 2>&1 || return 0
  qm config "$NAS_ID" | grep -qx "hookscript: local:snippets/$BULK_HOOK_NAME" \
    || qm set "$NAS_ID" --hookscript "local:snippets/$BULK_HOOK_NAME" >/dev/null
  if [ "$(qm status "$NAS_ID" | cut -d' ' -f2)" = running ]; then pvesm set bulk --disable 1; fi
}

# -----------------------------------------------------------------------------
# MONITORING
# -----------------------------------------------------------------------------

exporter_converge() {
  local collector
  install -d -m 0755 "$TEXTFILE_DIR"
  echo "ARGS=\"--collector.textfile.directory=$TEXTFILE_DIR\"" \
    | file_converge /etc/default/prometheus-node-exporter 644 systemctl restart prometheus-node-exporter
  systemctl -q enable --now prometheus-node-exporter
  for collector in smartmon nvme; do systemctl -q enable --now "prometheus-node-exporter-$collector.timer"; done

  # guests overprovision local-lvm (pve/data) and bulk/data; a full thin pool pauses every guest on it, and
  # node_exporter has no lvm collector, so lvs feeds gauges that vm-105 alerts on
  textfile_job_install thinpool-metrics "LVM thin pool fill" 1m <<'METRICS'
#!/usr/bin/env bash
# fill of every thin pool on this host, for node_exporter's textfile collector
set -euo pipefail
# lvm localizes the decimal separator; prometheus wants a dot
export LC_ALL=C
pools=$(lvs --noheadings --nosuffix --units b --separator '|' --select 'segtype=thin-pool' \
    -o vg_name,lv_name,lv_size,data_percent,metadata_percent)
{
  echo "# HELP homelab_thinpool_size_bytes Size of an LVM thin pool."
  echo "# TYPE homelab_thinpool_size_bytes gauge"
  echo "# HELP homelab_thinpool_data_percent Data space used in an LVM thin pool."
  echo "# TYPE homelab_thinpool_data_percent gauge"
  echo "# HELP homelab_thinpool_metadata_percent Metadata space used in an LVM thin pool."
  echo "# TYPE homelab_thinpool_metadata_percent gauge"
  while IFS='|' read -r vg lv size data meta; do
    vg=${vg//[[:space:]]/}
    [ -n "$vg" ] || continue
    labels="vg=\"$vg\",lv=\"${lv//[[:space:]]/}\""
    echo "homelab_thinpool_size_bytes{$labels} ${size//[[:space:]]/}"
    echo "homelab_thinpool_data_percent{$labels} ${data//[[:space:]]/}"
    echo "homelab_thinpool_metadata_percent{$labels} ${meta//[[:space:]]/}"
  done <<<"$pools"
} > "$TEXTFILE_DIR/thinpool.prom.tmp"
mv "$TEXTFILE_DIR/thinpool.prom.tmp" "$TEXTFILE_DIR/thinpool.prom"
METRICS

  # smartd's warnings become a gauge vm-105 alerts on, instead of mail to a root mailbox nobody reads
  file_converge /usr/local/bin/smartd-textfile 755 <<SMARTD
#!/bin/sh
# run by smartd on a warning: SMARTD_DEVICE, SMARTD_FAILTYPE; one file per device and kind of failure
set -eu
name=\$(printf '%s-%s' "\$SMARTD_DEVICE" "\$SMARTD_FAILTYPE" | tr -c 'A-Za-z0-9\n' _)
{
  echo "# HELP homelab_smartd_warning_timestamp_seconds When smartd last warned about a disk."
  echo "# TYPE homelab_smartd_warning_timestamp_seconds gauge"
  echo "homelab_smartd_warning_timestamp_seconds{device=\"\$SMARTD_DEVICE\",type=\"\$SMARTD_FAILTYPE\"} \$(date +%s)"
} > "$TEXTFILE_DIR/smartd-\$name.prom.tmp"
mv "$TEXTFILE_DIR/smartd-\$name.prom.tmp" "$TEXTFILE_DIR/smartd-\$name.prom"
SMARTD
  echo "DEVICESCAN -d removable -n standby -m root -M exec /usr/local/bin/smartd-textfile" \
    | file_converge /etc/smartd.conf 644 systemctl restart smartd
}

# host intrusion detection, built from the pinned source; the binary marks a finished install, so a half one from an
# interrupted run is removed and built again. The install prefix is compiled in, so it cannot be staged elsewhere.
ossec_converge() {
  local tmp
  if [ ! -x "$OSSEC_CONTROL" ]; then
    echo ">>> Proxmox: building OSSEC $OSSEC_VERSION"
    rm -rf "$OSSEC_DIR"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${OSSEC_BUILD_PACKAGES[@]}" </dev/null >/dev/null
    tmp=$(mktemp -d)
    wget -qO "$tmp/ossec.tar.gz" "https://github.com/ossec/ossec-hids/archive/refs/tags/$OSSEC_VERSION.tar.gz"
    echo "$OSSEC_SHA256  $tmp/ossec.tar.gz" | sha256sum --check --quiet
    tar -xzf "$tmp/ossec.tar.gz" -C "$tmp"
    # install.sh is interactive; USER_* answers it
    (
      cd "$tmp/ossec-hids-$OSSEC_VERSION"
      USER_LANGUAGE=en USER_NO_STOP=y USER_INSTALL_TYPE=local USER_DIR="$OSSEC_DIR" \
      USER_ENABLE_ACTIVE_RESPONSE=n USER_ENABLE_SYSCHECK=y USER_ENABLE_ROOTCHECK=y \
      USER_ENABLE_EMAIL=n USER_ENABLE_SYSLOG=y \
      ./install.sh </dev/null
    )
    rm -rf "$tmp"
  fi

  # realtime where the kernel supports it
  echo "syscheck.sleep=2" | file_converge "$OSSEC_DIR/etc/local_internal_options.conf" 644
  if ! grep -q "homelab-managed" "$OSSEC_DIR/etc/ossec.conf"; then
    python3 - "$OSSEC_DIR/etc/ossec.conf" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
# 6h not 12h: catch /etc/pve changes the same day
text = text.replace("<frequency>43200</frequency>", "<frequency>21600</frequency>")
watch = """  <!-- homelab-managed: see src/scripts/pve-install.sh -->
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
"""
open(path, "w").write(text.replace("</ossec_config>", watch + "</ossec_config>", 1))
PY
  fi
  # the source install ships no unit: without one ossec would not come back after a host reboot
  file_converge /etc/systemd/system/ossec.service 644 systemctl daemon-reload <<UNIT
[Unit]
Description=OSSEC host intrusion detection
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$OSSEC_CONTROL start
ExecStop=$OSSEC_CONTROL stop

[Install]
WantedBy=multi-user.target
UNIT
  systemctl -q enable --now ossec

  textfile_job_install ossec-metrics "OSSEC alert counts" 5m <<METRICS
#!/usr/bin/env bash
# today's ossec alerts by severity (7+ notable, 10+ urgent)
set -euo pipefail
log=$OSSEC_DIR/logs/alerts/alerts.log
total=0; high=0; up=0
if [ -r "\$log" ]; then
  # grep -c prints the 0 itself, it only exits 1
  total=\$(grep -c "^\*\* Alert" "\$log" || true)
  high=\$(grep -cE "Level: (1[0-9]|[7-9])" "\$log" || true)
fi
if pgrep -x ossec-analysisd >/dev/null; then up=1; fi
{
  echo "# HELP homelab_ossec_alerts_total OSSEC alerts on the hypervisor."
  echo "# TYPE homelab_ossec_alerts_total gauge"
  echo "homelab_ossec_alerts_total \$total"
  echo "# HELP homelab_ossec_alerts_high OSSEC alerts at level 7 or above."
  echo "# TYPE homelab_ossec_alerts_high gauge"
  echo "homelab_ossec_alerts_high \$high"
  echo "# HELP homelab_ossec_up Whether ossec-analysisd is running."
  echo "# TYPE homelab_ossec_up gauge"
  echo "homelab_ossec_up \$up"
} > "\$TEXTFILE_DIR/ossec.prom.tmp"
mv "\$TEXTFILE_DIR/ossec.prom.tmp" "\$TEXTFILE_DIR/ossec.prom"
METRICS
}

# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

main() {
  command -v pveversion >/dev/null || { echo "ERROR: install Proxmox VE first, then rerun init.sh." >&2; exit 1; }
  apt_converge
  bridges_converge
  gpu_converge
  power_converge
  root_converge
  users_converge
  realm_converge
  api_cert_converge
  bulk_converge
  exporter_converge
  ossec_converge
  echo ">>> Proxmox $(pveversion) converged."
}

main
