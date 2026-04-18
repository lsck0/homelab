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
