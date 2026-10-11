#!/usr/bin/env bash
# tear the lab down again: pve-install.sh's teardown on the Proxmox host; the local terraform state copy is set aside,
# so the next deploy starts fresh (TF_STATE_FRESH=1)
#
# usage: src/scripts/deinit.sh [--yes] [proxmox-ip]   (the ip defaults to src/generated/site.json's lan.proxmox)
# Proxmox's host key must be pinned in src/generated/known_hosts (init.sh --pin); no other key is accepted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$ROOT_DIR/src"
# shellcheck source=src/scripts/lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=src/scripts/lib/proxmox.sh
. "$SCRIPT_DIR/lib/proxmox.sh"
# shellcheck source=src/scripts/lib/tfstate.sh
. "$SCRIPT_DIR/lib/tfstate.sh"
tools_require ssh ssh-keygen jq

usage() { echo "usage: src/scripts/deinit.sh [--yes] [proxmox-ip]" >&2; exit 2; }

ASSUME_YES=0
TARGET_IP=""
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) [ -z "$TARGET_IP" ] || usage; TARGET_IP="$arg" ;;
  esac
done
if [ -z "$TARGET_IP" ] && [ -f "$LAB_SITE" ]; then TARGET_IP=$(jq -r '.lan.proxmox // empty' "$LAB_SITE"); fi
[ -n "$TARGET_IP" ] || { echo "ERROR: no Proxmox address: pass it, or run init.sh, which writes src/generated/site.json."; exit 1; }

# the ssh login, from the tfvars when they exist
tfvars_temp=$(umask 077; mktemp --suffix=.tfvars.json)
trap 'rm -f "$tfvars_temp"' EXIT
[ ! -f "$PROXMOX_TFVARS_ENC" ] || tools_require sops
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/secrets/age.txt}" proxmox_tfvars_load "$tfvars_temp" \
  || echo ">>> no tfvars: logging in as $PROXMOX_SSH_USER_DEFAULT on port $PROXMOX_SSH_PORT_DEFAULT"
proxmox_login_load
proxmox_ssh_init "$TARGET_IP" "$PROXMOX_SSH_PORT"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This destroys all VMs and LXCs on $TARGET_IP and what pve-install.sh set up (its teardown lists what stays)."
  echo "The local terraform state copy is set aside."
  read -r -p "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
fi

echo ">>> Resetting Proxmox host $TARGET_IP..."
proxmox_teardown "$TARGET_IP"

tfstate_set_aside
echo ">>> Proxmox reset complete."
echo ">>> Next: ./src/scripts/init.sh $TARGET_IP, then TF_STATE_FRESH=1 ./sync.sh"
