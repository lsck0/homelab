#!/usr/bin/env bash
# tear the lab down again: every guest on the Proxmox host and what pve-install.sh set up
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
if [ -z "$TARGET_IP" ] && [ -f "$SRC/generated/site.json" ]; then TARGET_IP=$(jq -r '.lan.proxmox // empty' "$SRC/generated/site.json"); fi
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
  echo "This destroys all VMs and LXCs on $TARGET_IP and removes what pve-install.sh set up: bridges, api users,"
  echo "tokens and roles, the lldap realm, node-exporter, the golden image and lxc template."
  echo "Kept: OSSEC, the bulk storage, gpu passthrough, apt repos and sync.sh's power and module settings."
  read -r -p "Type 'yes' to continue: " confirm
  [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
fi

echo ">>> Resetting Proxmox host $TARGET_IP..."
"${PROXMOX_SSH[@]}" "${PROXMOX_SSH_USER}@${TARGET_IP}" "bash -s" <<'REMOTE'
set -euo pipefail
# best effort per object (`|| true`): a guest already stopped or a user, pool or package already gone is no error

for id in $(qm list | awk 'NR>1 {print $1}'); do
  qm stop "$id" --skiplock 1 >/dev/null 2>&1 || true
  qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1 >/dev/null
done

for id in $(pct list | awk 'NR>1 {print $1}'); do
  pct stop "$id" >/dev/null 2>&1 || true
  pct destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null
done

rm -f /var/lib/vz/template/iso/nixos.img /var/lib/vz/template/cache/nixos-homelab.tar.xz
rm -f /root/terraform_token.txt /root/wake_token*.txt /root/homepage_token.txt

# deleting a user deletes its tokens and acl entries
for user in $(pveum user list --output-format json | jq -r '.[].userid | select(test("^(terraform-prov|homepage|wake(-.*)?)@pve$"))'); do
  pveum user delete "$user" >/dev/null 2>&1 || true
done
for pool in $(pveum pool list --output-format json | jq -r '.[].poolid | select(startswith("wake-"))'); do
  pveum pool delete "$pool" >/dev/null 2>&1 || true
done
pveum role delete HomelabWake >/dev/null 2>&1 || true
pveum realm delete lldap >/dev/null 2>&1 || true
rm -f /etc/pve/priv/realm/lldap.pw

systemctl disable --now prometheus-node-exporter >/dev/null 2>&1 || true
apt-get purge -y prometheus-node-exporter >/dev/null 2>&1 || true
apt-get autoremove -y >/dev/null 2>&1 || true

for bridge in $(sed -n 's/^auto \(vmbr[1-9][0-9]*\)$/\1/p' /etc/network/interfaces); do
  sed -i "/^auto $bridge\$/,/^\$/d" /etc/network/interfaces
done
ifreload -a >/dev/null 2>&1 || true

echo "QM_AFTER"
qm list
echo "PCT_AFTER"
pct list
REMOTE

echo ">>> Proxmox reset complete."
echo ">>> Next: ./src/scripts/init.sh $TARGET_IP"
