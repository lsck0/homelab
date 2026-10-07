#!/usr/bin/env bash
# initialize the homelab against an existing proxmox ve
#
# usage: src/scripts/init.sh <proxmox-ip>         pin the host key, ask the site, make secrets, set up proxmox
#        src/scripts/init.sh --pin <proxmox-ip>   only (re)pin Proxmox's ssh host key in src/generated/known_hosts
#
# The pin is the root of every later ssh: sync.sh and deinit.sh refuse any other key for Proxmox, and read every
# guest's key through it. It is taken once, after the owner compared the fingerprint with the one the Proxmox
# console shows, never from the network alone.
set -euo pipefail

usage() {
  echo "usage: src/scripts/init.sh <proxmox-ip>" >&2
  echo "       src/scripts/init.sh --pin <proxmox-ip>    (re)pin Proxmox's host key only" >&2
  exit 2
}
PIN_ONLY=0
case "${1:-}" in
  --pin) PIN_ONLY=1; shift ;;
  -*|"") usage ;;
esac
[ $# = 1 ] || usage
TARGET_IP=$1
KEYSCAN_TIMEOUT_S=5
# of the bulk disk's bytes, the thin pool and its metadata fit in this share
BULK_POOL_SHARE=0.96
BYTES_PER_GIB=1073741824
LLDAP_ID=101

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$ROOT_DIR/src"
# shellcheck source=src/scripts/lib/tools.sh
. "$SCRIPT_DIR/lib/tools.sh"
# shellcheck source=src/scripts/lib/proxmox.sh
. "$SCRIPT_DIR/lib/proxmox.sh"
SSH_PORT=$PROXMOX_SSH_PORT_DEFAULT
# shellcheck source=src/scripts/lib/secrets.sh
. "$SCRIPT_DIR/lib/secrets.sh"
tools_require ssh ssh-keyscan ssh-keygen jq
[ "$PIN_ONLY" = 1 ] || tools_require sops openssl git nix age-keygen wg

# -----------------------------------------------------------------------------
# PIN: Proxmox's ed25519 host key, confirmed against the console
# -----------------------------------------------------------------------------
pinned_host=$(proxmox_pinned_host "$TARGET_IP" "$SSH_PORT")
pin() {
  local scanned fingerprint answer
  scanned=$(ssh-keyscan -T "$KEYSCAN_TIMEOUT_S" -t ed25519 -p "$SSH_PORT" "$TARGET_IP" 2>/dev/null | grep -v '^#') \
    || { echo "ERROR: no ssh host key from $TARGET_IP:$SSH_PORT"; exit 1; }
  fingerprint=$(ssh-keygen -lf - <<<"$scanned" | awk '{print $2}')
  echo ">>> $TARGET_IP presents the ssh host key $fingerprint"
  echo "    On the Proxmox console (not over the network) run: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  read -r -p "    Does it print $fingerprint? Type 'yes' to pin it: " answer </dev/tty
  [ "$answer" = yes ] || { echo "Not pinned."; exit 1; }
  touch "$LAB_KNOWN_HOSTS"
  # every other line (the guests' keys, written by sync.sh) stays; grep fails on a file with no other line
  { grep -v -F "$pinned_host " "$LAB_KNOWN_HOSTS" || true; awk '{print $2 " " $3}' <<<"$scanned" | sed "s|^|$pinned_host |"; } \
    > "$LAB_KNOWN_HOSTS.new"
  mv "$LAB_KNOWN_HOSTS.new" "$LAB_KNOWN_HOSTS"
  echo ">>> Pinned in src/generated/known_hosts; commit it (sync.sh does)."
}
if [ "$PIN_ONLY" = 1 ] || ! ssh-keygen -F "$pinned_host" -f "$LAB_KNOWN_HOSTS" >/dev/null 2>&1; then
  pin
fi
[ "$PIN_ONLY" = 1 ] && exit 0

echo ">>> Initializing Lab on Proxmox at $TARGET_IP..."
# a commit before the first sync gets the plaintext guard too
git -C "$ROOT_DIR" config core.hooksPath .githooks

if [ -z "${HOMELAB_ROOT_PASSWORD:-}" ]; then
  echo ">>> Enter root password for $TARGET_IP (leave blank if using SSH keys):"
  read -r -s -p "Password: " ROOT_PASS
  echo ""
else
  ROOT_PASS="$HOMELAB_ROOT_PASSWORD"
fi

proxmox_ssh_init "$TARGET_IP" "$SSH_PORT" "$ROOT_PASS"

if ! "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER_DEFAULT@$TARGET_IP" "pveversion" >/dev/null 2>&1; then
  echo "ERROR: Cannot reach Proxmox at $TARGET_IP."
  echo "Ensure Proxmox VE is installed, the credentials are correct and the pinned key is its own (init.sh --pin)."
  exit 1
fi
echo ">>> Connected to $("${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER_DEFAULT@$TARGET_IP" "pveversion")"


# -----------------------------------------------------------------------------
# SITE: the machine and the house network, asked once and kept in src/generated/site.json for terraform, nix and sync.sh
# -----------------------------------------------------------------------------
SITE="$SRC/generated/site.json"
[ -f "$SITE" ] || echo '{}' > "$SITE"
pve() { "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER_DEFAULT@$TARGET_IP" "$@"; }
# ask <question> <default>; enter keeps the default, "-" clears it
ask() {
  local answer
  read -r -p "$1 [${2:--}]: " answer </dev/tty
  case "$answer" in "") echo "$2" ;; -) echo "" ;; *) echo "$answer" ;; esac
}
old() { jq -r "$1 // empty" "$SITE"; }

echo ">>> Site: enter keeps the value in brackets, '-' clears it"
LAN_SUBNET=$(pve "ip -4 route show dev vmbr0 scope link" | awk '{print $1; exit}')
LAN_GATEWAY=$(pve "ip -4 route show default" | awk '{print $3; exit}')
WORKSTATION=$(ip -4 route get "$TARGET_IP" | sed -n 's/.* src \([0-9.]*\).*/\1/p')
WORKSTATION_MAC=$(ip -o link show "$(ip -4 route get "$TARGET_IP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')" | sed -n 's/.*link\/ether \([0-9a-f:]*\).*/\1/p')
DOMAIN=$(ask "public domain, every service is <name>.<domain>" "$(old .domain)")
TIME_ZONE=$(ask "the house's time zone (tz database name)" "$(old .timeZone)")
REPO=$(ask "this repository on github (owner/name), which hermes opens pull requests on" "$(old .repo)")
ROUTER=$(ask "router address on the lan (forward 443 and 25565 to it)" "$(old .lan.router)")
INVERTER=$(ask "fronius inverter address" "$(old .lan.inverter)")
# vm-109's smb shares admit the workstation and the notebook, both dhcp-reserved in the fritzbox
NOTEBOOK=$(ask "notebook address on the lan" "$(old .lan.notebook)")
NOTEBOOK_MAC=$(ask "notebook mac address" "$(old .lan.notebookMac)")

echo ">>> GPUs on the host:"
pve "lspci -nn -D | grep -E 'VGA|3D controller'" | nl -w2 -s') '
GPU_PATH=$(ask "gpu to pass through to jellyfin (pci path)" "$(old .gpu.path)")

echo ">>> Disks on the host (the nvme pool is local-lvm; the bulk disk gets wiped once):"
pve "lsblk -dno NAME,SIZE,ROTA,MODEL; ls -l /dev/disk/by-id/ | grep -v -- -part | awk '/ata-|nvme-|scsi-/ {print \$9, \$11}'"
BULK_DISK=$(ask "bulk disk for media (/dev/disk/by-id/...)" "$(old .bulk.disk)")

GPU_JSON=null
if [ -n "$GPU_PATH" ]; then
  gpu_id() { pve "lspci -n -s $1" | awk '{print $3}'; }
  GPU_JSON=$(jq -n \
    --arg id "$(gpu_id "$GPU_PATH")" \
    --arg sub "$(pve "lspci -vmmn -s $GPU_PATH" | awk '/^SVendor/ {v=$2} /^SDevice/ {d=$2} END {print v":"d}')" \
    --arg path "$GPU_PATH" \
    --argjson group "$(pve "basename \$(readlink /sys/bus/pci/devices/$GPU_PATH/iommu_group)")" \
    --argjson functions "$(gpu_id "${GPU_PATH%.*}" | jq -R . | jq -s .)" \
    '{id: $id, subsystemId: $sub, path: $path, iommuGroup: $group, functionIds: $functions}')
fi
BULK_JSON=null
if [ -n "$BULK_DISK" ]; then
  # a disk already in use keeps its size, terraform cannot shrink
  BULK_JSON=$(jq -n --arg disk "$BULK_DISK" --argjson bytes "$(pve "lsblk -dbno SIZE $BULK_DISK")" \
    --argjson old "$(jq --arg d "$BULK_DISK" 'if .bulk.disk == $d then .bulk.sizeGiB else null end' "$SITE")" \
    --argjson gib "$BYTES_PER_GIB" --argjson share "$BULK_POOL_SHARE" \
    '{disk: $disk, sizeGiB: ($old // ($bytes / $gib * $share | floor))}')
fi
# the cluster ca, read over the pinned ssh: hosts that call the proxmox api verify its tls against it
PROXMOX_CA=$(pve "cat /etc/pve/pve-root-ca.pem")
# merged into what is there: keys this script does not ask for stay
jq --arg node "$(pve hostname)" --arg domain "$DOMAIN" --arg ca "$PROXMOX_CA" --arg subnet "$LAN_SUBNET" --arg gateway "$LAN_GATEWAY" --arg router "$ROUTER" \
  --arg proxmox "$TARGET_IP" --arg workstation "$WORKSTATION" --arg mac "$WORKSTATION_MAC" --arg inverter "$INVERTER" \
  --arg notebook "$NOTEBOOK" --arg notebookMac "$NOTEBOOK_MAC" --arg timeZone "$TIME_ZONE" --arg repo "$REPO" \
  --argjson gpu "$GPU_JSON" --argjson bulk "$BULK_JSON" '. * {
    node: $node,
    domain: $domain,
    timeZone: $timeZone,
    repo: $repo,
    lan: { subnet: $subnet, gateway: $gateway, router: $router, proxmox: $proxmox, workstation: $workstation,
           inverter: $inverter, workstationMac: $mac, notebook: $notebook, notebookMac: $notebookMac }
  } | .gpu = $gpu | .bulk = $bulk | .proxmoxCa = $ca' "$SITE" > "$SITE.new" && mv "$SITE.new" "$SITE"
echo ">>> Wrote $SITE"

# age key's source of truth is the dotfiles repo; src/secrets/admins.txt lists its public key
AGE_KEY="$ROOT_DIR/secrets/age.txt"
secrets_age_key_link "$AGE_KEY"
if ! grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY"; then
  echo "ERROR: $AGE_KEY is not an age key: unlock the dotfiles secrets ($SECRETS_DOTFILES/scripts/yubikey.sh unlock)."
  exit 1
fi
export SOPS_AGE_KEY_FILE="$AGE_KEY"

# every declared secret in its file, generated where secrets-sync.sh can; then the formats it cannot generate
echo ">>> Generating secrets..."
"$SCRIPT_DIR/secrets-sync.sh" --apply
[ -n "$(secrets_get wireguard-private-key)" ] || secrets_set wireguard-private-key "$(wg genkey)"
[ -n "$(secrets_get firefly-app-key)" ] || secrets_set firefly-app-key "base64:$(openssl rand -base64 32)"

mkdir -p "$ROOT_DIR/images"
if [ ! -f "$ROOT_DIR/images/nixos.img" ]; then
  echo ">>> Building NixOS golden image..."
  sudo nix build "$SRC#cloud-image" \
    --extra-experimental-features "nix-command flakes" \
    -o "$ROOT_DIR/images/nixos-build"
  IMG_FILE=$(sudo find -L "$ROOT_DIR/images/nixos-build" -name "*.qcow2" -o -name "*.img" 2>/dev/null | head -n 1)
  sudo cp --dereference "$IMG_FILE" "$ROOT_DIR/images/nixos.img"
  sudo chown "$(id -un):$(id -gn)" "$ROOT_DIR/images/nixos.img"
  sudo rm -rf "$ROOT_DIR/images/nixos-build"
fi

echo ">>> Configuring Proxmox (bridges + API token)..."
# the realm's read-only lldap user; pve-install skips the ldap realm without it, so an unset one reads as empty
LLDAP_BIND_PASSWORD=$(secrets_get lldap-proxmox-bind-password 2>/dev/null || true)
LLDAP_HOST=$(nix eval --raw --no-warn-dirty "$SRC#lab.inventory.\"$LLDAP_ID\".ip")
# the zones whose ingress wakes onDemand guests: each gets a token for its own pool only
WAKE_ZONES=$(jq -r '[to_entries[] | select(.value.ingress != null) | .key] | join(" ")' "$SRC/generated/zones.json")
# every zone's bridge, created on the host when missing
ZONE_BRIDGES=$(jq -r '[.[].bridge] | join(" ")' "$SRC/generated/zones.json")
# passwords go ahead of the script on stdin, never onto the ssh command line
{
  printf 'LLDAP_BIND_PASSWORD=%q\nLLDAP_HOST=%q\nGPU_IDS=%q\nBULK_DISK=%q\nWAKE_ZONES=%q\nZONE_BRIDGES=%q\n' \
    "$LLDAP_BIND_PASSWORD" "$LLDAP_HOST" "$(jq -r '.gpu.functionIds // [] | join(",")' "$SITE")" \
    "$(jq -r '.bulk.disk // empty' "$SITE")" "$WAKE_ZONES" "$ZONE_BRIDGES"
  cat "$SCRIPT_DIR/pve-install.sh"
} | "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER_DEFAULT@$TARGET_IP" "bash -s"
unset LLDAP_BIND_PASSWORD

# the token secrets leave the host once read: they live in sops from here on
read_token() { "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER_DEFAULT@$TARGET_IP" "cat /root/$1 && rm -f /root/$1"; }
TOKEN_SECRET=$(read_token terraform_token.txt)
HOMEPAGE_TOKEN=$(read_token homepage_token.txt)

jq -n \
  --arg proxmox_api_token_id "terraform-prov@pve!terraform-token" \
  --arg proxmox_api_token_secret "$TOKEN_SECRET" \
  --arg proxmox_datastore "local-lvm" \
  --argjson proxmox_ssh_port "$SSH_PORT" \
  --arg proxmox_ssh_user "$PROXMOX_SSH_USER_DEFAULT" \
  '{
    proxmox_api_token_id: $proxmox_api_token_id,
    proxmox_api_token_secret: $proxmox_api_token_secret,
    proxmox_datastore: $proxmox_datastore,
    proxmox_ssh_port: $proxmox_ssh_port,
    proxmox_ssh_user: $proxmox_ssh_user,
    proxmox_insecure: true
  }' | "$SCRIPT_DIR/sops-encrypt.sh" "$PROXMOX_TFVARS_ENC"
rm -f "$PROXMOX_TFVARS_PLAIN"

echo ">>> Storing the Homepage and on-demand wake Proxmox API tokens in secrets..."
secrets_set proxmox-user "homepage@pve!homepage"
secrets_set proxmox-pass "$HOMEPAGE_TOKEN"
# the traefiks verify the proxmox api against it (on-demand wake)
secrets_set proxmox-ca "$PROXMOX_CA"
for zone in $WAKE_ZONES; do
  secrets_set "proxmox-wake-token-$zone" "wake-$zone@pve!ondemand=$(read_token "wake_token_$zone.txt")"
done
unset TOKEN_SECRET HOMEPAGE_TOKEN

echo ">>> INIT COMPLETE!"
echo ">>> External secrets (cloudflare-token, telegram-*, ...): fill the empty ones secrets-sync.sh listed with 'sops <file>'"
echo ">>> Terraform connection vars: encrypted at src/terraform/terraform.tfvars.sops.json"
echo ">>> Next step: ./sync.sh"
