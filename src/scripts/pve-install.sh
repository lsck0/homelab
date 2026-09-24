#!/bin/bash
# Configure an existing Proxmox VE host for Terraform management.
# Creates internal/external bridges and a Terraform API token.
# Usage: ssh root@proxmox "bash -s" < pve-install.sh <terraform_user_password>
set -e

PVE_TF_PASSWORD="${1:-}"
if [ -z "$PVE_TF_PASSWORD" ]; then
    echo "ERROR: Terraform Proxmox user password is required."
    exit 1
fi
# Optional second argument: the lldap bind password. Without it the LDAP realm
# step is skipped rather than half-configured.
LLDAP_BIND_PASSWORD="${2:-}"
LLDAP_HOST="${LLDAP_HOST:-10.100.0.102}"
LLDAP_PORT="${LLDAP_PORT:-3890}"
LLDAP_BASE_DN="${LLDAP_BASE_DN:-dc=lsck0,dc=dev}"
# the lldap group whose members get Administrator on the whole datacentre
LLDAP_ADMIN_GROUP="${LLDAP_ADMIN_GROUP:-admins}"

if ! command -v pveversion &>/dev/null; then
    echo "ERROR: This script expects Proxmox VE to be installed already."
    echo "Install Proxmox first, then re-run src/scripts/init.sh."
    exit 1
fi
echo ">>> Proxmox VE $(pveversion) detected."

# configure APT repos for non-subscription installs.
CODENAME="$(
    . /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
)"

# disable enterprise repos that require paid subscription.
echo ">>> Disabling enterprise repos..."
for file in $(grep -rl "enterprise.proxmox.com" /etc/apt/ || true); do
    if [[ "$file" == *.sources ]]; then
        echo ">>> Disabling DEB822 file: $file"
        mv "$file" "/root/$(basename "$file").disabled"
    else
        echo ">>> Commenting out enterprise repo in: $file"
        sed -i 's|^.*enterprise\.proxmox\.com.*|# &|g' "$file"
    fi
done

# ensure Proxmox no-subscription repo exists.
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription
EOF

# vmbr0 is created by the Proxmox installer. vmbr100/vmbr200 are
# purely virtual networks between the router VM and other VMs (no host IPs).

if ! grep -q "auto vmbr100" /etc/network/interfaces; then
    cat <<EOF >> /etc/network/interfaces

auto vmbr100
iface vmbr100 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
fi

if ! grep -q "auto vmbr200" /etc/network/interfaces; then
    cat <<EOF >> /etc/network/interfaces

auto vmbr200
iface vmbr200 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
fi

ifreload -a || true

# quiet + low-power tuning (server lives in a bedroom)
# powersave governor caps clocks at idle; disabling boost stops the short,
# loud, hot frequency spikes that spin fans up. Small throughput cost, large
# noise/heat/power win. Applied now and made persistent across reboots.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo powersave > "$g" 2>/dev/null || true
done
# AMD global boost toggle (cpufreq) and, as fallback, the pstate knob.
echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
echo 1 > /sys/devices/system/cpu/amd_pstate/cpb_boost 2>/dev/null || true
# spin down idle spinning disks after ~10 min.
for d in /dev/sd?; do hdparm -S 120 "$d" 2>/dev/null || true; done

cat > /etc/systemd/system/lab-lowpower.service <<'EOF'
[Unit]
Description=Low-power/quiet tuning (governor + no boost)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > "$g" 2>/dev/null || true; done; echo 0 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now lab-lowpower.service >/dev/null 2>&1 || true

# GPU passthrough (NVIDIA RTX 2060 / TU106)
# Bind the GPU and its HDMI-audio function to vfio-pci so a VM can claim them.
# whole IOMMU group must be bound to vfio-pci for the group to be assignable,
# even though only the VGA function is assigned to the VM:
#   10de:1f08 VGA, 10de:10f9 audio, 10de:1ada USB, 10de:1adb UCSI.
# idempotent; needs a reboot.
GPU_IDS="10de:1f08,10de:10f9,10de:1ada,10de:1adb"

# AMD host: enable the IOMMU in passthrough mode on the GRUB kernel cmdline.
if ! grep -q "amd_iommu=on" /etc/default/grub; then
    echo ">>> Enabling IOMMU on kernel cmdline..."
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_iommu=on iommu=pt"/' /etc/default/grub
    UPDATE_BOOT=1
fi

# load the vfio stack at boot.
if [ ! -f /etc/modules-load.d/vfio.conf ]; then
    printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/vfio.conf
    UPDATE_BOOT=1
fi

# claim the GPU for vfio-pci and keep the host's nouveau/nvidia drivers off it.
if [ ! -f /etc/modprobe.d/vfio.conf ]; then
    echo "options vfio-pci ids=${GPU_IDS}" > /etc/modprobe.d/vfio.conf
    printf 'blacklist nouveau\nblacklist nvidia\nblacklist nvidiafb\nblacklist snd_hda_intel\n' > /etc/modprobe.d/blacklist-gpu.conf
    UPDATE_BOOT=1
fi

if [ "${UPDATE_BOOT:-0}" = "1" ]; then
    echo ">>> Updating GRUB + initramfs for GPU passthrough (reboot required)..."
    update-initramfs -u -k all >/dev/null 2>&1 || true
    update-grub >/dev/null 2>&1 || true
    echo ">>> GPU passthrough staged. REBOOT the Proxmox host to bind vfio-pci."
fi

# Proxmox host metrics exporter for Prometheus/Grafana.
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y prometheus-node-exporter >/dev/null
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true

if ! pveum user list 2>/dev/null | grep -q "terraform-prov@pve"; then
    pveum user add terraform-prov@pve --password "$PVE_TF_PASSWORD" >/dev/null 2>&1 || true
else
    pveum user modify terraform-prov@pve --password "$PVE_TF_PASSWORD" >/dev/null 2>&1 || true
fi

pveum acl modify / -user terraform-prov@pve -role Administrator

# recreate token on each run so src/scripts/init.sh always gets a fresh secret.
pveum user token delete terraform-prov@pve terraform-token >/dev/null 2>&1 || true
TOKEN_SECRET="$(
    pveum user token add terraform-prov@pve terraform-token --privsep 0 \
      | awk -F'│' '/^[[:space:]]*│[[:space:]]*value[[:space:]]*│/ {gsub(/[[:space:]]/, "", $3); print $3; exit}'
)"

if [ -z "$TOKEN_SECRET" ]; then
    echo "ERROR: Failed to extract terraform API token secret."
    exit 1
fi

printf '%s\n' "$TOKEN_SECRET" > /root/terraform_token.txt
chmod 600 /root/terraform_token.txt

# Homepage read-only user for dashboard widget
if ! pveum user list 2>/dev/null | grep -q "homepage@pve"; then
    pveum user add homepage@pve --password "homepage-readonly" >/dev/null 2>&1 || true
fi
pveum acl modify / -user homepage@pve -role PVEAuditor

# recreate homepage API token
pveum user token delete homepage@pve homepage >/dev/null 2>&1 || true
HOMEPAGE_TOKEN="$(
    pveum user token add homepage@pve homepage --privsep 0 \
      | awk -F'│' '/^[[:space:]]*│[[:space:]]*value[[:space:]]*│/ {gsub(/[[:space:]]/, "", $3); print $3; exit}'
)"
printf '%s\n' "$HOMEPAGE_TOKEN" > /root/homepage_token.txt
chmod 600 /root/homepage_token.txt


# ─────────────────────────────────────────────────────────────────────────────
# LDAP REALM (lldap)
# ─────────────────────────────────────────────────────────────────────────────
# So the one lldap account signs in here too, rather than Proxmox being the
# odd one out with its own local password. Proxmox talks to lldap directly
# rather than through Authelia: the web UI has no OIDC support in PVE 8, and
# the API needs an auth source that a CLI can use.
#
# Proxmox names a synced group "<cn>-<realm>", so the lldap group "admins"
# arrives as "admins-lldap". Users land as "<uid>@lldap".
if [ -z "$LLDAP_BIND_PASSWORD" ]; then
    echo ">>> No lldap bind password given, skipping the LDAP realm."
else
    echo ">>> Configuring the lldap LDAP realm..."
    # The bind password lives in a file Proxmox owns; there is no CLI flag.
    mkdir -p /etc/pve/priv/realm
    printf '%s' "$LLDAP_BIND_PASSWORD" > /etc/pve/priv/realm/lldap.pw
    chmod 600 /etc/pve/priv/realm/lldap.pw

    # add or update: re-running init.sh must not fail on an existing realm.
    REALM_VERB=add
    pveum realm list --output-format json 2>/dev/null | grep -q '"lldap"' && REALM_VERB=modify
    pveum realm "$REALM_VERB" lldap \
        --type ldap \
        --server1 "$LLDAP_HOST" \
        --port "$LLDAP_PORT" \
        --mode ldap \
        --base_dn "ou=people,$LLDAP_BASE_DN" \
        --user_attr uid \
        --bind_dn "uid=admin,ou=people,$LLDAP_BASE_DN" \
        --group_dn "ou=groups,$LLDAP_BASE_DN" \
        --group_name_attr cn \
        --group_classes groupOfUniqueNames \
        --sync-defaults-options "enable-new=1,scope=both" \
        --comment "lldap (single sign-on account store)"

    pveum realm sync lldap
    # Administrator on / for the lldap admins group. Idempotent: acl modify
    # adds the entry and says nothing if it is already there.
    pveum acl modify / --group "$LLDAP_ADMIN_GROUP-lldap" --role Administrator
    echo ">>> lldap realm ready: sign in as <user>@lldap"
fi

# ─────────────────────────────────────────────────────────────────────────────
# BULK STORAGE (the spinning disk)
# ─────────────────────────────────────────────────────────────────────────────
# NVMes carry the VMs and their state; the 2 TB spinning disk carries media.
# Keeping media out of the `pve` group is the point: it once filled the pool
# the VMs live in and took the whole lab down at once.
#
# The provider has no storage resource, so this runs here and instances.tf asks
# for a disk on `bulk` by name. Idempotent.
BULK_DISK=${BULK_DISK:-/dev/disk/by-id/ata-WDC_WD20EZRZ-00Z5HB0_WD-WCC4N3KNZ2KS}
if ! vgs bulk >/dev/null 2>&1; then
    if [ ! -b "$BULK_DISK" ]; then
        echo ">>> bulk disk $BULK_DISK not present; skipping bulk storage"
    elif lsblk -no FSTYPE "$BULK_DISK" 2>/dev/null | grep -q .; then
        # Refuse to wipe a disk that still holds a filesystem. This one shipped
        # with an NTFS partition full of personal files; they were copied off
        # deliberately before it was handed over, and a rerun of this script
        # must never make that decision on its own.
        echo ">>> $BULK_DISK still has a filesystem on it; refusing to wipe."
        echo ">>> Clear it by hand once its contents are safe, then re-run."
    else
        echo ">>> Creating bulk storage on $BULK_DISK"
        pvcreate -ff -y "$BULK_DISK"
        vgcreate bulk "$BULK_DISK"
        # Leave 1% for thin-pool metadata growth: a thin pool whose metadata
        # fills is as wedged as one whose data fills, and far more annoying.
        lvcreate --type thin-pool -l 99%FREE --thinpool data bulk
    fi
fi
if vgs bulk >/dev/null 2>&1 && ! pvesm status --storage bulk >/dev/null 2>&1; then
    pvesm add lvmthin bulk --vgname bulk --thinpool data --content images
    echo ">>> Proxmox storage 'bulk' ready"
fi

# ─────────────────────────────────────────────────────────────────────────────
# OSSEC (host intrusion detection)
# ─────────────────────────────────────────────────────────────────────────────
# The hypervisor is the one machine a HIDS earns its keep on. Every VM is an
# immutable NixOS system, so FIM there restates what Nix already guarantees;
# this host is mutable Debian holding the API token and root on every VM.
#
# `local` mode: no manager, no agents, no listener. The lab ran a Wazuh manager
# for months with an agent on nothing, costing 4 GiB to duplicate promtail.
#
# Built from source: Atomicorp has no Debian 13 channel, and pointing trixie at
# bookworm packages is a poor trade on the hypervisor.
OSSEC_VERSION=${OSSEC_VERSION:-3.8.0}
if [ ! -d /var/ossec ]; then
    echo ">>> Building OSSEC $OSSEC_VERSION"
    apt-get install -y --no-install-recommends \
        build-essential libevent-dev libpcre2-dev libz-dev libssl-dev wget ca-certificates
    tmp=$(mktemp -d)
    wget -qO "$tmp/ossec.tar.gz" \
        "https://github.com/ossec/ossec-hids/archive/refs/tags/$OSSEC_VERSION.tar.gz"
    tar -xzf "$tmp/ossec.tar.gz" -C "$tmp"
    # Unattended: install.sh is interactive, but every prompt has a USER_*
    # override. Active response stays off - it reacts by running commands as
    # root, and a false positive that firewalls the hypervisor off the network
    # is a worse day than the intrusion it was guessing at.
    (
        cd "$tmp/ossec-hids-$OSSEC_VERSION"
        USER_LANGUAGE=en USER_NO_STOP=y USER_INSTALL_TYPE=local USER_DIR=/var/ossec \
        USER_ENABLE_ACTIVE_RESPONSE=n USER_ENABLE_SYSCHECK=y USER_ENABLE_ROOTCHECK=y \
        USER_ENABLE_EMAIL=n USER_ENABLE_SYSLOG=y \
        ./install.sh
    )
    rm -rf "$tmp"
fi

# What to watch. Written every run so the list stays in this repo rather than
# in a file someone edited on the box two years ago.
if [ -d /var/ossec ]; then
    cat > /var/ossec/etc/local_internal_options.conf <<'OPTS'
# report changes in real time where the kernel can tell us, rather than only
# on the scan interval.
syscheck.sleep=2
OPTS
    if ! grep -q "homelab-managed" /var/ossec/etc/ossec.conf 2>/dev/null; then
        python3 - <<'PY'
import re
p = "/var/ossec/etc/ossec.conf"
s = open(p).read()
# 6h rather than the 12h default: a change to /etc/pve wants finding the same
# day, and the tree is small enough that scanning it costs nothing.
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
    systemctl enable --now ossec 2>/dev/null || /var/ossec/bin/ossec-control restart
fi

# OSSEC's alerts reach Grafana the same way the backup dead-man does: a gauge
# in node_exporter's textfile directory, scraped from vm-105. Without this the
# alerts sit in a file on a host nobody reads.
if [ -d /var/ossec ]; then
    install -d -m 0755 /var/lib/node-exporter-textfile
    if ! grep -q "node-exporter-textfile" /etc/default/prometheus-node-exporter 2>/dev/null; then
        echo 'ARGS="--collector.textfile.directory=/var/lib/node-exporter-textfile"' \
            > /etc/default/prometheus-node-exporter
        systemctl restart prometheus-node-exporter
    fi
    cat > /usr/local/bin/ossec-metrics <<'METRICS'
#!/usr/bin/env bash
# Count today's OSSEC alerts by severity for the node_exporter textfile
# collector. Levels: 7+ is worth seeing, 10+ is worth waking up for.
set -euo pipefail
log=/var/ossec/logs/alerts/alerts.log
d=/var/lib/node-exporter-textfile
total=0; high=0
if [ -r "$log" ]; then
  total=$(grep -c "^\*\* Alert" "$log" 2>/dev/null || echo 0)
  high=$(grep -cE "Level: (1[0-9]|[7-9])" "$log" 2>/dev/null || echo 0)
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
  echo "homelab_ossec_up $(pgrep -x ossec-analysisd >/dev/null && echo 1 || echo 0)"
} > "$d/ossec.prom.tmp"
mv "$d/ossec.prom.tmp" "$d/ossec.prom"
METRICS
    chmod +x /usr/local/bin/ossec-metrics
    cat > /etc/systemd/system/ossec-metrics.service <<'UNIT'
[Unit]
Description=Publish OSSEC alert counts for node_exporter
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ossec-metrics
UNIT
    cat > /etc/systemd/system/ossec-metrics.timer <<'UNIT'
[Unit]
Description=Publish OSSEC alert counts every 5 minutes
[Timer]
OnBootSec=5m
OnUnitActiveSec=5m
[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    systemctl enable --now ossec-metrics.timer
    echo ">>> OSSEC ready (local mode); metrics via node_exporter textfile"
fi
