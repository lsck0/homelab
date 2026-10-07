#!/usr/bin/env bash
# configure an existing Proxmox VE host for terraform management
#
# Run by init.sh over ssh, which prepends these on stdin, out of argv: LLDAP_BIND_PASSWORD (lldap's
# read-only proxmox-bind user; empty skips the realm), LLDAP_HOST (vm-101), GPU_IDS and BULK_DISK (src/generated/site.json; empty
# skips that part), WAKE_ZONES (the zones whose ingress wakes onDemand guests; terraform/lib.tf grants their wake user each onDemand guest)
# and ZONE_BRIDGES (every zone's bridge), both from src/generated/zones.json.
set -euo pipefail

: "${LLDAP_HOST:?the address of lldap}"
: "${WAKE_ZONES:?the zones with an ingress}" "${ZONE_BRIDGES:?the bridge of every zone}"
LLDAP_BIND_PASSWORD="${LLDAP_BIND_PASSWORD:-}"
GPU_IDS="${GPU_IDS:-}"
BULK_DISK="${BULK_DISK:-}"
LLDAP_PORT="${LLDAP_PORT:-3890}"
LLDAP_BASE_DN="${LLDAP_BASE_DN:-dc=lsck0,dc=dev}"
# read-only (lldap_strict_readonly): the realm sync reads users and groups and never writes
LLDAP_BIND_USER="${LLDAP_BIND_USER:-proxmox-bind}"
# lldap group granted datacentre admin
LLDAP_ADMIN_GROUP="${LLDAP_ADMIN_GROUP:-admins}"
# debian's textfile directory: its collector timers write there, and so do the thin pool and ossec gauges below
TEXTFILE_DIR=/var/lib/prometheus/node-exporter
TEXTFILE_INTERVAL_MIN=5
OSSEC_VERSION=3.8.0
# sha256 of github's source archive of that tag, checked before anything of it runs as root
OSSEC_SHA256=bd857a2dd7d0559ef59b4a9ec276f3a8ade6830f8aed257e8f4a62106cfe5f38

if ! command -v pveversion &>/dev/null; then
    echo "ERROR: This script expects Proxmox VE to be installed already."
    echo "Install Proxmox first, then re-run src/scripts/init.sh."
    exit 1
fi
echo ">>> Proxmox VE $(pveversion) detected."

CODENAME="$(
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
)"

# enterprise repos need a paid subscription
echo ">>> Disabling enterprise repos..."
# grep fails when no file names the enterprise repo any more
for file in $(grep -rl "enterprise.proxmox.com" /etc/apt/ || true); do
    if [[ "$file" == *.sources ]]; then
        echo ">>> Disabling DEB822 file: $file"
        mv "$file" "/root/$(basename "$file").disabled"
    else
        echo ">>> Commenting out enterprise repo in: $file"
        sed -i 's|^.*enterprise\.proxmox\.com.*|# &|g' "$file"
    fi
done

cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription
EOF

# vmbr0 comes from the installer; every zone's bridge (src/generated/zones.json) is virtual, firewalled apart by the router
for bridge in $ZONE_BRIDGES; do
    grep -q "auto $bridge\$" /etc/network/interfaces && continue
    printf '\nauto %s\niface %s inet manual\n    bridge-ports none\n    bridge-stp off\n    bridge-fd 0\n' "$bridge" "$bridge" \
        >> /etc/network/interfaces
done

# best effort: an unrelated interface ifupdown2 cannot bring up must not stop the host setup
ifreload -a || true

# gpu passthrough: iommu on, the gpu's functions bound to vfio-pci instead of their drivers
if [ -n "$GPU_IDS" ]; then
    iommu=$(grep -q GenuineIntel /proc/cpuinfo && echo intel_iommu || echo amd_iommu)
    if ! grep -q "${iommu}=on" /etc/default/grub; then
        echo ">>> Enabling IOMMU on kernel cmdline..."
        sed -i "s/\\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\\)\"/\\1 ${iommu}=on iommu=pt\"/" /etc/default/grub
        UPDATE_BOOT=1
    fi
    if [ ! -f /etc/modules-load.d/vfio.conf ]; then
        printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/vfio.conf
        UPDATE_BOOT=1
    fi
    if [ "$(cat /etc/modprobe.d/vfio.conf 2>/dev/null)" != "options vfio-pci ids=${GPU_IDS}" ]; then
        echo "options vfio-pci ids=${GPU_IDS}" > /etc/modprobe.d/vfio.conf
        printf 'blacklist nouveau\nblacklist nvidia\nblacklist nvidiafb\nblacklist snd_hda_intel\n' > /etc/modprobe.d/blacklist-gpu.conf
        UPDATE_BOOT=1
    fi
    if [ "${UPDATE_BOOT:-0}" = "1" ]; then
        echo ">>> Updating GRUB + initramfs for GPU passthrough (reboot required)..."
        update-initramfs -u -k all >/dev/null
        update-grub >/dev/null
        echo ">>> GPU passthrough staged. REBOOT the Proxmox host to bind vfio-pci."
    fi
fi

# host metrics exporter for prometheus, with debian's smart and nvme collectors (the disk health and wear alerts)
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y prometheus-node-exporter prometheus-node-exporter-collectors smartmontools nvme-cli moreutils jq >/dev/null
install -d -m 0755 "$TEXTFILE_DIR"
if ! grep -q "$TEXTFILE_DIR" /etc/default/prometheus-node-exporter 2>/dev/null; then
    echo "ARGS=\"--collector.textfile.directory=$TEXTFILE_DIR\"" > /etc/default/prometheus-node-exporter
    systemctl restart prometheus-node-exporter
fi
# the directory earlier installs used; gauges left there would never update again
rm -rf /var/lib/node-exporter-textfile
systemctl -q enable --now prometheus-node-exporter
for collector in smartmon nvme; do
    systemctl enable --now "prometheus-node-exporter-$collector.timer"
done

# pveum's json, read whole by jq: grep -q closing the pipe early would fail it under pipefail
pve_user_exists() { pveum user list --output-format json | jq -e --arg u "$1" '.[] | select(.userid == $u)' >/dev/null; }

# recreate an api token (pve shows its secret only once) and keep the secret for init.sh
token_save() {
    local file=$1 secret
    shift
    # absent on the first run
    pveum user token delete "$1" "$2" >/dev/null 2>&1 || true
    secret=$(pveum user token add "$@" --output-format json | jq -r '.value // empty')
    [ -n "$secret" ] || { echo "ERROR: Failed to create API token $1!$2."; exit 1; }
    (umask 077; printf '%s\n' "$secret" > "$file")
}

# token only, like every lab user here: terraform authenticates with the token, a password would be unused
pve_user_exists terraform-prov@pve || pveum user add terraform-prov@pve

pveum acl modify / -user terraform-prov@pve -role Administrator
token_save /root/terraform_token.txt terraform-prov@pve terraform-token --privsep 0

# on-demand wake per zone: terraform grants each zone's user and token HomelabWake on exactly its onDemand guests
# (terraform/lib.tf wake acls), so the edge's token powers nothing but the dmz's sleepers.
# A privsep token gets what both it and its user are granted, so both get each guest.
pveum role list --output-format json | jq -e '.[] | select(.roleid == "HomelabWake")' >/dev/null \
    || pveum role add HomelabWake --privs "VM.Audit,VM.PowerMgmt"
for zone in $WAKE_ZONES; do
    user="wake-$zone@pve"
    pve_user_exists "$user" || pveum user add "$user" --comment "on-demand wake, $zone ingress"
    token_save "/root/wake_token_$zone.txt" "$user" ondemand --privsep 1 --comment "$zone traefik on-demand"
    # the per-zone pools of the first per-zone design, empty: grants are per guest now
    if pveum pool list --output-format json | jq -e --arg p "wake-$zone" '.[] | select(.poolid == $p)' >/dev/null; then
        pveum pool delete "wake-$zone"
    fi
done
# the former single token, valid on every vm and held by both ingresses
if pve_user_exists wake@pve; then
    pveum user delete wake@pve
fi
rm -f /root/wake_token.txt

# read-only user for the homepage widget: api token only, no password
pve_user_exists homepage@pve || pveum user add homepage@pve
pveum acl modify / -user homepage@pve -role PVEAuditor
token_save /root/homepage_token.txt homepage@pve homepage --privsep 0

# -----------------------------------------------------------------------------
# LDAP REALM (lldap)
# -----------------------------------------------------------------------------
if [ -z "$LLDAP_BIND_PASSWORD" ]; then
    echo ">>> No lldap bind password given, skipping the LDAP realm."
else
    echo ">>> Configuring the lldap LDAP realm..."
    # bind password is file-only, no cli flag
    mkdir -p /etc/pve/priv/realm
    printf '%s' "$LLDAP_BIND_PASSWORD" > /etc/pve/priv/realm/lldap.pw
    chmod 600 /etc/pve/priv/realm/lldap.pw

    # add or update so reruns never fail; the type is fixed at creation, modify refuses it
    REALM_CREATE=(add lldap --type ldap)
    if pveum realm list --output-format json | jq -e '.[] | select(.realm == "lldap")' >/dev/null; then REALM_CREATE=(modify lldap); fi
    pveum realm "${REALM_CREATE[@]}" \
        --server1 "$LLDAP_HOST" \
        --port "$LLDAP_PORT" \
        --mode ldap \
        --base_dn "ou=people,$LLDAP_BASE_DN" \
        --user_attr uid \
        --bind_dn "uid=$LLDAP_BIND_USER,ou=people,$LLDAP_BASE_DN" \
        --group_dn "ou=groups,$LLDAP_BASE_DN" \
        --group_name_attr cn \
        --group_classes groupOfUniqueNames \
        --sync-defaults-options "enable-new=1,scope=both" \
        --comment "lldap (single sign-on account store)"

    # the bind user exists once vm-101 runs the config that creates it: a first install syncs on its rerun
    if pveum realm sync lldap; then
        pveum acl modify / --group "$LLDAP_ADMIN_GROUP-lldap" --role Administrator
        echo ">>> lldap realm ready: sign in as <user>@lldap"
    else
        echo ">>> lldap realm configured, not synced: lldap refused $LLDAP_BIND_USER. Rerun init.sh once vm-101 is deployed."
    fi
fi

# -----------------------------------------------------------------------------
# BULK STORAGE (the spinning disk)
# -----------------------------------------------------------------------------
if [ -n "$BULK_DISK" ] && ! vgs bulk >/dev/null 2>&1; then
    if [ ! -b "$BULK_DISK" ]; then
        echo ">>> bulk disk $BULK_DISK not present; skipping bulk storage"
    elif [ -n "$(lsblk -no FSTYPE "$BULK_DISK")" ]; then
        # never wipe a disk holding a filesystem
        echo ">>> $BULK_DISK still has a filesystem on it; refusing to wipe."
        echo ">>> Clear it by hand once its contents are safe, then re-run."
    else
        echo ">>> Creating bulk storage on $BULK_DISK"
        pvcreate -ff -y "$BULK_DISK"
        vgcreate bulk "$BULK_DISK"
        # 1% spare: full thin metadata wedges the pool
        lvcreate --type thin-pool -l 99%FREE -Zn --thinpool data bulk
    fi
fi
if vgs bulk >/dev/null 2>&1 && ! pvesm status --storage bulk >/dev/null 2>&1; then
    pvesm add lvmthin bulk --vgname bulk --thinpool data --content images
    echo ">>> Proxmox storage 'bulk' ready"
fi

# -----------------------------------------------------------------------------
# TEXTFILE GAUGES
# -----------------------------------------------------------------------------
# textfile_job_install <name> <what it publishes> <first run after boot>: the script on stdin becomes
# /usr/local/bin/<name>, run every TEXTFILE_INTERVAL_MIN by a timer with TEXTFILE_DIR in its environment
textfile_job_install() {
    local name=$1 what=$2 boot_delay=$3
    cat > "/usr/local/bin/$name"
    chmod +x "/usr/local/bin/$name"
    cat > "/etc/systemd/system/$name.service" <<UNIT
[Unit]
Description=Publish $what for node_exporter
[Service]
Type=oneshot
Environment=TEXTFILE_DIR=$TEXTFILE_DIR
ExecStart=/usr/local/bin/$name
UNIT
    cat > "/etc/systemd/system/$name.timer" <<UNIT
[Unit]
Description=Publish $what every $TEXTFILE_INTERVAL_MIN minutes
[Timer]
OnBootSec=$boot_delay
OnUnitActiveSec=${TEXTFILE_INTERVAL_MIN}m
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$name.timer"
}

# guests overprovision local-lvm (pve/data) and bulk/data; a full thin pool pauses every guest on it, and
# node_exporter has no lvm collector, so lvs feeds textfile gauges that vm-105 alerts on
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
# first sample now, not 5 minutes after a fresh install
systemctl start thinpool-metrics.service

# -----------------------------------------------------------------------------
# OSSEC (host intrusion detection)
# -----------------------------------------------------------------------------
if [ ! -d /var/ossec ]; then
    echo ">>> Building OSSEC $OSSEC_VERSION"
    apt-get install -y --no-install-recommends \
        build-essential libevent-dev libpcre2-dev libz-dev libssl-dev libsystemd-dev wget ca-certificates
    tmp=$(mktemp -d)
    wget -qO "$tmp/ossec.tar.gz" \
        "https://github.com/ossec/ossec-hids/archive/refs/tags/$OSSEC_VERSION.tar.gz"
    echo "$OSSEC_SHA256  $tmp/ossec.tar.gz" | sha256sum --check --quiet
    tar -xzf "$tmp/ossec.tar.gz" -C "$tmp"
    # install.sh is interactive; USER_* answers it
    (
        cd "$tmp/ossec-hids-$OSSEC_VERSION"
        USER_LANGUAGE=en USER_NO_STOP=y USER_INSTALL_TYPE=local USER_DIR=/var/ossec \
        USER_ENABLE_ACTIVE_RESPONSE=n USER_ENABLE_SYSCHECK=y USER_ENABLE_ROOTCHECK=y \
        USER_ENABLE_EMAIL=n USER_ENABLE_SYSLOG=y \
        ./install.sh
    )
    rm -rf "$tmp"
fi

if [ -d /var/ossec ]; then
    cat > /var/ossec/etc/local_internal_options.conf <<'OPTS'
# realtime where the kernel supports it
syscheck.sleep=2
OPTS
    if ! grep -q "homelab-managed" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - <<'PY'
import re
p = "/var/ossec/etc/ossec.conf"
s = open(p).read()
# 6h not 12h: catch /etc/pve changes same day
s = s.replace("<frequency>43200</frequency>", "<frequency>21600</frequency>")
watch = """  <!-- homelab-managed: see src/scripts/pve-install.sh -->
  <syscheck>
    <directories check_all="yes" realtime="yes">/etc,/usr/bin,/usr/sbin,/bin,/sbin</directories>
    <!-- the cluster filesystem: VM configs, the API tokens, the ACLs -->
    <directories check_all="yes" realtime="yes">/etc/pve</directories>
    <!-- noisy and rewritten constantly; watching it reports nothing useful -->
    <ignore>/etc/pve/.version</ignore>
    <ignore>/etc/pve/.members</ignore>
    <ignore>/etc/pve/.rrd</ignore>
    <ignore>/etc/pve/.vmlist</ignore>
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/adjtime</ignore>
  </syscheck>
"""
s = s.replace("</ossec_config>", watch + "</ossec_config>", 1)
open(p, "w").write(s)
PY
    fi
    # the source install ships no unit: without one ossec would not come back after a host reboot
    cat > /etc/systemd/system/ossec.service <<'UNIT'
[Unit]
Description=OSSEC host intrusion detection
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/var/ossec/bin/ossec-control start
ExecStop=/var/ossec/bin/ossec-control stop

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now ossec

    # alerts reach grafana as a textfile gauge
    textfile_job_install ossec-metrics "OSSEC alert counts" 5m <<'METRICS'
#!/usr/bin/env bash
# today's ossec alerts by severity (7+ notable, 10+ urgent)
set -euo pipefail
log=/var/ossec/logs/alerts/alerts.log
total=0; high=0
if [ -r "$log" ]; then
  # grep -c prints the 0 itself, it only exits 1
  total=$(grep -c "^\*\* Alert" "$log" || true)
  high=$(grep -cE "Level: (1[0-9]|[7-9])" "$log" || true)
fi
{
  echo "# HELP homelab_ossec_alerts_total OSSEC alerts on the hypervisor."
  echo "# TYPE homelab_ossec_alerts_total gauge"
  echo "homelab_ossec_alerts_total $total"
  echo "# HELP homelab_ossec_alerts_high OSSEC alerts at level 7 or above."
  echo "# TYPE homelab_ossec_alerts_high gauge"
  echo "homelab_ossec_alerts_high $high"
  echo "# HELP homelab_ossec_up Whether ossec-analysisd is running."
  echo "# TYPE homelab_ossec_up gauge"
  up=0
  if pgrep -x ossec-analysisd >/dev/null; then up=1; fi
  echo "homelab_ossec_up $up"
} > "$TEXTFILE_DIR/ossec.prom.tmp"
mv "$TEXTFILE_DIR/ossec.prom.tmp" "$TEXTFILE_DIR/ossec.prom"
METRICS
    echo ">>> OSSEC ready (local mode); metrics via node_exporter textfile"
fi
