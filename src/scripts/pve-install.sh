#!/bin/bash
# Configure an existing Proxmox VE host for Terraform management.
set -e

# init.sh prepends PVE_TF_PASSWORD, the optional LLDAP_BIND_PASSWORD and the site's GPU_IDS and BULK_DISK
# (src/site.json) on stdin, keeping them out of argv; an empty GPU_IDS or BULK_DISK skips that part
if [ -z "${PVE_TF_PASSWORD:-}" ]; then
    echo "ERROR: Terraform Proxmox user password is required."
    exit 1
fi
LLDAP_HOST="${LLDAP_HOST:-10.100.0.101}"
LLDAP_PORT="${LLDAP_PORT:-3890}"
LLDAP_BASE_DN="${LLDAP_BASE_DN:-dc=lsck0,dc=dev}"
# lldap group granted datacentre admin
LLDAP_ADMIN_GROUP="${LLDAP_ADMIN_GROUP:-admins}"

if ! command -v pveversion &>/dev/null; then
    echo "ERROR: This script expects Proxmox VE to be installed already."
    echo "Install Proxmox first, then re-run src/scripts/init.sh."
    exit 1
fi
echo ">>> Proxmox VE $(pveversion) detected."

# apt repos for non-subscription installs
CODENAME="$(
    . /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
)"

# enterprise repos need a paid subscription
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

# ensure the no-subscription repo exists
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription
EOF

# vmbr0 comes from the installer; vmbr100/200 are virtual

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

# gpu passthrough: iommu on, the gpu's functions bound to vfio-pci instead of their drivers
if [ -n "${GPU_IDS:-}" ]; then
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
        update-initramfs -u -k all >/dev/null 2>&1 || true
        update-grub >/dev/null 2>&1 || true
        echo ">>> GPU passthrough staged. REBOOT the Proxmox host to bind vfio-pci."
    fi
fi

# host metrics exporter for prometheus
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y prometheus-node-exporter jq >/dev/null
systemctl enable --now prometheus-node-exporter >/dev/null 2>&1 || true

# recreate an api token (pve shows its secret only once) and keep the secret for init.sh
token_save() {
    local file=$1 secret
    shift
    pveum user token delete "$1" "$2" >/dev/null 2>&1 || true
    secret=$(pveum user token add "$@" --output-format json | jq -r '.value // empty')
    [ -n "$secret" ] || { echo "ERROR: Failed to create API token $1!$2."; exit 1; }
    (umask 077; printf '%s\n' "$secret" > "$file")
}

if ! pveum user list 2>/dev/null | grep -q "terraform-prov@pve"; then
    pveum user add terraform-prov@pve --password "$PVE_TF_PASSWORD" >/dev/null 2>&1 || true
else
    pveum user modify terraform-prov@pve --password "$PVE_TF_PASSWORD" >/dev/null 2>&1 || true
fi

pveum acl modify / -user terraform-prov@pve -role Administrator
token_save /root/terraform_token.txt terraform-prov@pve terraform-token --privsep 0

# on-demand wake from the traefiks: status, start, shutdown and nothing else
pveum role list 2>/dev/null | grep -q HomelabWake || pveum role add HomelabWake --privs "VM.Audit,VM.PowerMgmt"
pveum user list 2>/dev/null | grep -q "wake@pve" || pveum user add wake@pve --comment "on-demand wake"
pveum acl modify /vms --users wake@pve --roles HomelabWake
token_save /root/wake_token.txt wake@pve ondemand --privsep 1 --comment "traefik on-demand"
pveum acl modify /vms --tokens 'wake@pve!ondemand' --roles HomelabWake

# read-only user for the homepage widget: api token only, no password
pveum user list 2>/dev/null | grep -q "homepage@pve" || pveum user add homepage@pve
pveum acl modify / -user homepage@pve -role PVEAuditor
token_save /root/homepage_token.txt homepage@pve homepage --privsep 0


# -----------------------------------------------------------------------------
# LDAP REALM (lldap)
if [ -z "$LLDAP_BIND_PASSWORD" ]; then
    echo ">>> No lldap bind password given, skipping the LDAP realm."
else
    echo ">>> Configuring the lldap LDAP realm..."
    # bind password is file-only, no cli flag
    mkdir -p /etc/pve/priv/realm
    printf '%s' "$LLDAP_BIND_PASSWORD" > /etc/pve/priv/realm/lldap.pw
    chmod 600 /etc/pve/priv/realm/lldap.pw

    # add or update so reruns never fail
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
    # administrator on / for lldap admins
    pveum acl modify / --group "$LLDAP_ADMIN_GROUP-lldap" --role Administrator
    echo ">>> lldap realm ready: sign in as <user>@lldap"
fi

# -----------------------------------------------------------------------------
# BULK STORAGE (the spinning disk)
if [ -n "${BULK_DISK:-}" ] && ! vgs bulk >/dev/null 2>&1; then
    if [ ! -b "$BULK_DISK" ]; then
        echo ">>> bulk disk $BULK_DISK not present; skipping bulk storage"
    elif lsblk -no FSTYPE "$BULK_DISK" 2>/dev/null | grep -q .; then
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
# OSSEC (host intrusion detection)
OSSEC_VERSION=${OSSEC_VERSION:-3.8.0}
if [ ! -d /var/ossec ]; then
    echo ">>> Building OSSEC $OSSEC_VERSION"
    apt-get install -y --no-install-recommends \
        build-essential libevent-dev libpcre2-dev libz-dev libssl-dev wget ca-certificates
    tmp=$(mktemp -d)
    wget -qO "$tmp/ossec.tar.gz" \
        "https://github.com/ossec/ossec-hids/archive/refs/tags/$OSSEC_VERSION.tar.gz"
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
    systemctl enable --now ossec 2>/dev/null || /var/ossec/bin/ossec-control restart
fi

# alerts reach grafana as a textfile gauge
if [ -d /var/ossec ]; then
    install -d -m 0755 /var/lib/node-exporter-textfile
    if ! grep -q "node-exporter-textfile" /etc/default/prometheus-node-exporter 2>/dev/null; then
        echo 'ARGS="--collector.textfile.directory=/var/lib/node-exporter-textfile"' \
            > /etc/default/prometheus-node-exporter
        systemctl restart prometheus-node-exporter
    fi
    cat > /usr/local/bin/ossec-metrics <<'METRICS'
#!/usr/bin/env bash
# today's ossec alerts by severity (7+ notable, 10+ urgent)
set -euo pipefail
log=/var/ossec/logs/alerts/alerts.log
d=/var/lib/node-exporter-textfile
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
