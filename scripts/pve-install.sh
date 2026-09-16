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

if ! command -v pveversion &>/dev/null; then
    echo "ERROR: This script expects Proxmox VE to be installed already."
    echo "Install Proxmox first, then re-run scripts/init.sh."
    exit 1
fi
echo ">>> Proxmox VE $(pveversion) detected."

# Configure APT repos for non-subscription installs.
CODENAME="$(
    . /etc/os-release
    echo "${VERSION_CODENAME:-bookworm}"
)"

# Disable enterprise repos that require paid subscription.
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

# Ensure Proxmox no-subscription repo exists.
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

# ── GPU passthrough (NVIDIA RTX 2060 / TU106) ────────────────────────────────
# Bind the GPU and its HDMI-audio function to vfio-pci so a VM can claim them.
# Whole IOMMU group must be bound to vfio-pci for the group to be assignable,
# even though only the VGA function is assigned to the VM:
#   10de:1f08 VGA, 10de:10f9 audio, 10de:1ada USB, 10de:1adb UCSI.
# Idempotent; needs a reboot.
GPU_IDS="10de:1f08,10de:10f9,10de:1ada,10de:1adb"

# AMD host: enable the IOMMU in passthrough mode on the GRUB kernel cmdline.
if ! grep -q "amd_iommu=on" /etc/default/grub; then
    echo ">>> Enabling IOMMU on kernel cmdline..."
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 amd_iommu=on iommu=pt"/' /etc/default/grub
    UPDATE_BOOT=1
fi

# Load the vfio stack at boot.
if [ ! -f /etc/modules-load.d/vfio.conf ]; then
    printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' > /etc/modules-load.d/vfio.conf
    UPDATE_BOOT=1
fi

# Claim the GPU for vfio-pci and keep the host's nouveau/nvidia drivers off it.
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

# Recreate token on each run so scripts/init.sh always gets a fresh secret.
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

# Recreate homepage API token
pveum user token delete homepage@pve homepage >/dev/null 2>&1 || true
HOMEPAGE_TOKEN="$(
    pveum user token add homepage@pve homepage --privsep 0 \
      | awk -F'│' '/^[[:space:]]*│[[:space:]]*value[[:space:]]*│/ {gsub(/[[:space:]]/, "", $3); print $3; exit}'
)"
printf '%s\n' "$HOMEPAGE_TOKEN" > /root/homepage_token.txt
chmod 600 /root/homepage_token.txt
