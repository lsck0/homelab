#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS_PATH="$ROOT_DIR/src/terraform.tfvars"
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"
ACTIVE_TFVARS_PATH=""
HAS_TFVARS=0

usage() {
  echo "Usage: ./scripts/deinit.sh [--yes] [PROXMOX_IP]"
}

read_tfvar_string() {
  local key="$1"
  [ "$HAS_TFVARS" -eq 1 ] || return 0
  jq -r --arg key "$key" 'if has($key) and .[$key] != null then .[$key] else empty end' "$ACTIVE_TFVARS_PATH"
}

read_tfvar_int() {
  local key="$1"
  [ "$HAS_TFVARS" -eq 1 ] || return 0
  jq -r --arg key "$key" 'if has($key) and .[$key] != null then .[$key] else empty end' "$ACTIVE_TFVARS_PATH"
}

load_tfvars() {
  if [ -f "$TFVARS_PATH" ]; then
    ACTIVE_TFVARS_PATH="$TFVARS_PATH"
    HAS_TFVARS=1
    return 0
  fi

  if [ ! -f "$TFVARS_ENC_PATH" ]; then
    HAS_TFVARS=0
    return 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    echo "ERROR: sops required to decrypt $TFVARS_ENC_PATH"
    exit 1
  fi

  ACTIVE_TFVARS_PATH="$(mktemp)"
  if [ -f "$ROOT_DIR/secrets/age.txt" ]; then
    SOPS_AGE_KEY_FILE="$ROOT_DIR/secrets/age.txt" sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  else
    sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  fi
  trap 'rm -f "$ACTIVE_TFVARS_PATH"' EXIT
  HAS_TFVARS=1
}

ASSUME_YES=0
TARGET_IP=""

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [ -z "$TARGET_IP" ]; then
        TARGET_IP="$arg"
      else
        usage
        exit 1
      fi
      ;;
  esac
done

load_tfvars || true

if [ -z "$TARGET_IP" ]; then
  if [ "$HAS_TFVARS" -ne 1 ]; then
    echo "ERROR: Missing tfvars and no host provided."
    exit 1
  fi
  TARGET_IP="$(read_tfvar_string proxmox_ssh_host)"
fi

if [ -z "$TARGET_IP" ]; then
  echo "ERROR: Could not determine Proxmox host."
  exit 1
fi

SSH_PORT="22"
SSH_USER="root"
SSH_PASSWORD=""

if [ "$HAS_TFVARS" -eq 1 ]; then
  SSH_PORT="$(read_tfvar_int proxmox_ssh_port)"
  SSH_USER="$(read_tfvar_string proxmox_ssh_user)"
  SSH_PASSWORD="$(read_tfvar_string proxmox_ssh_password)"
fi

[ -n "$SSH_PORT" ] || SSH_PORT="22"
[ -n "$SSH_USER" ] || SSH_USER="root"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This destroys all VMs and LXCs on $TARGET_IP and removes homelab Proxmox bootstrap artifacts."
  read -r -p "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "[$TARGET_IP]:$SSH_PORT" >/dev/null 2>&1 || true
if ! ssh-keyscan -p "$SSH_PORT" -H "$TARGET_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null; then
  echo "ERROR: Could not fetch SSH host key for $TARGET_IP:$SSH_PORT"
  exit 1
fi

if [ -n "$SSH_PASSWORD" ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: proxmox_ssh_password set but sshpass not installed."
    exit 1
  fi
  SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=yes -p "$SSH_PORT")
else
  SSH_CMD=(ssh -o StrictHostKeyChecking=yes -p "$SSH_PORT")
fi

echo ">>> Resetting Proxmox host $TARGET_IP..."
"${SSH_CMD[@]}" "${SSH_USER}@${TARGET_IP}" "bash -s" <<'REMOTE'
set -e

for id in $(qm list | awk 'NR>1 {print $1}'); do
  qm stop "$id" --skiplock 1 >/dev/null 2>&1 || true
  qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1 >/dev/null
done

for id in $(pct list | awk 'NR>1 {print $1}'); do
  pct stop "$id" >/dev/null 2>&1 || true
  pct destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null
done

rm -f /var/lib/vz/template/iso/nixos.img
rm -f /root/terraform_token.txt

pveum user token delete terraform-prov@pve terraform-token >/dev/null 2>&1 || true
pveum user delete terraform-prov@pve >/dev/null 2>&1 || true

systemctl disable --now prometheus-node-exporter >/dev/null 2>&1 || true
apt-get purge -y prometheus-node-exporter >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true

sed -i '/^auto vmbr100$/,/^$/d' /etc/network/interfaces
sed -i '/^auto vmbr200$/,/^$/d' /etc/network/interfaces
ifreload -a >/dev/null 2>&1 || true

echo "QM_AFTER"
qm list
echo "PCT_AFTER"
pct list
REMOTE

echo ">>> Proxmox reset complete."
echo ">>> Next: ./scripts/init.sh $TARGET_IP"
