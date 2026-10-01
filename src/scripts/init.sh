#!/bin/bash
# initialize the homelab against an existing proxmox ve
set -e

TARGET_IP=$1
SSH_PORT=22

if [ -z "$TARGET_IP" ]; then
    echo "Usage: ./src/scripts/init.sh <PROXMOX_IP>"
    echo "Example: ./src/scripts/init.sh 192.168.178.200"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

for tool in sops jq openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: '$tool' is required but not installed."
        exit 1
    fi
done

mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "[$TARGET_IP]:$SSH_PORT" >/dev/null 2>&1 || true
if ! ssh-keyscan -p "$SSH_PORT" -H "$TARGET_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null; then
    echo "ERROR: Could not fetch SSH host key for $TARGET_IP:$SSH_PORT"
    exit 1
fi


echo ">>> Initializing Lab on Proxmox at $TARGET_IP..."


if [ -z "${HOMELAB_ROOT_PASSWORD:-}" ]; then
    echo ">>> Enter root password for $TARGET_IP (leave blank if using SSH keys):"
    read -s -p "Password: " ROOT_PASS
    echo ""
else
    ROOT_PASS="$HOMELAB_ROOT_PASSWORD"
fi

if [ -n "$ROOT_PASS" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "ERROR: sshpass is required when using password auth."
        exit 1
    fi
    # sshpass -e reads it from the environment, out of argv
    export SSHPASS="$ROOT_PASS"
    SSH_CMD=(sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes)
else
    SSH_CMD=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes)
fi

if ! "${SSH_CMD[@]}" root@"$TARGET_IP" "pveversion" >/dev/null 2>&1; then
    echo "ERROR: Cannot reach Proxmox at $TARGET_IP."
    echo "Ensure Proxmox VE is installed and the credentials are correct."
    exit 1
fi
echo ">>> Connected to $("${SSH_CMD[@]}" root@"$TARGET_IP" "pveversion")"

if [ -z "${HOMELAB_PVE_TF_PASSWORD:-}" ]; then
    # reuse the root password to avoid a second prompt
    if [ -n "$ROOT_PASS" ]; then
        PVE_TF_PASSWORD="$ROOT_PASS"
    else
        PVE_TF_PASSWORD=$(openssl rand -base64 24)
    fi
else
    PVE_TF_PASSWORD="$HOMELAB_PVE_TF_PASSWORD"
fi


# -----------------------------------------------------------------------------
# SITE: the machine and the house network, asked once and kept in src/site.json for terraform, nix and sync.sh
SITE="$ROOT_DIR/src/site.json"
[ -f "$SITE" ] || echo '{}' > "$SITE"
pve() { "${SSH_CMD[@]}" root@"$TARGET_IP" "$@"; }
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
ROUTER=$(ask "router address on the lan (forward 443 and 25565 to it)" "$(old .lan.router)")
INVERTER=$(ask "fronius inverter address" "$(old .lan.inverter)")

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
    # 96% fits inside the thin pool and its metadata; a disk already in use keeps its size, terraform cannot shrink
    BULK_JSON=$(jq -n --arg disk "$BULK_DISK" --argjson bytes "$(pve "lsblk -dbno SIZE $BULK_DISK")" \
      --argjson old "$(jq --arg d "$BULK_DISK" 'if .bulk.disk == $d then .bulk.sizeGiB else null end' "$SITE")" \
      '{disk: $disk, sizeGiB: ($old // ($bytes / 1073741824 * 0.96 | floor))}')
fi
jq -n --arg node "$(pve hostname)" --arg subnet "$LAN_SUBNET" --arg gateway "$LAN_GATEWAY" --arg router "$ROUTER" \
  --arg proxmox "$TARGET_IP" --arg workstation "$WORKSTATION" --arg mac "$WORKSTATION_MAC" --arg inverter "$INVERTER" \
  --argjson gpu "$GPU_JSON" --argjson bulk "$BULK_JSON" '{
    node: $node,
    lan: { subnet: $subnet, gateway: $gateway, router: $router, proxmox: $proxmox,
           workstation: $workstation, inverter: $inverter, workstationMac: $mac },
    gpu: $gpu,
    bulk: $bulk
  }' > "$SITE.new" && mv "$SITE.new" "$SITE"
echo ">>> Wrote $SITE"

# age key's source of truth is the dotfiles repo; .sops.yaml lists its public key
AGE_KEY="$ROOT_DIR/secrets/age.txt"
AGE_KEY_SOURCE="${AGE_KEY_SOURCE:-$HOME/projects/arch-dotfiles/configs/secrets/age.txt}"
[ -e "$AGE_KEY" ] || { mkdir -p "$ROOT_DIR/secrets"; ln -sfn "$AGE_KEY_SOURCE" "$AGE_KEY"; }
if ! grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY"; then
    echo "ERROR: $AGE_KEY is not an age key: unlock the dotfiles secrets (~/projects/arch-dotfiles/scripts/yubikey.sh unlock)."
    exit 1
fi
export SOPS_AGE_KEY_FILE="$AGE_KEY"

SECRETS_FILE="$ROOT_DIR/src/secrets.json"
# the json value goes to sops on stdin, out of argv
secret_set() { printf '%s' "$2" | jq -Rs . | sops set --value-stdin "$SECRETS_FILE" "[\"$1\"]"; }

# only the formats secrets-sync.sh cannot generate; it adds every other key below
if [ ! -f "$SECRETS_FILE" ]; then
    echo ">>> Generating secrets..."
    jq -n \
      --arg wg "$(wg genkey 2>/dev/null || openssl rand -base64 32)" \
      --arg firefly "base64:$(openssl rand -base64 32)" \
      '{"wireguard-private-key": $wg, "firefly-app-key": $firefly}' > "$SECRETS_FILE"
    sops --encrypt --in-place "$SECRETS_FILE"
fi
"$ROOT_DIR/src/scripts/secrets-sync.sh" --apply


mkdir -p "$ROOT_DIR/images"

if [ ! -f "$ROOT_DIR/images/nixos.img" ]; then
    echo ">>> Building NixOS golden image..."
    sudo nix build "$ROOT_DIR/src#cloud-image" \
        --extra-experimental-features "nix-command flakes" \
        -o "$ROOT_DIR/images/nixos-build"
    IMG_FILE=$(sudo find -L "$ROOT_DIR/images/nixos-build" -name "*.qcow2" -o -name "*.img" 2>/dev/null | head -n 1)
    sudo cp --dereference "$IMG_FILE" "$ROOT_DIR/images/nixos.img"
    sudo chown "$(id -un):$(id -gn)" "$ROOT_DIR/images/nixos.img"
    sudo rm -rf "$ROOT_DIR/images/nixos-build"
fi


echo ">>> Configuring Proxmox (bridges + API token)..."
# pve-install skips the ldap realm without it
LLDAP_BIND_PASSWORD=$(sops -d "$SECRETS_FILE" 2>/dev/null \
  | jq -r '."lldap-admin-password" // empty')
# passwords go ahead of the script on stdin, never onto the ssh command line
{
    printf 'PVE_TF_PASSWORD=%q\nLLDAP_BIND_PASSWORD=%q\nGPU_IDS=%q\nBULK_DISK=%q\n' "$PVE_TF_PASSWORD" "$LLDAP_BIND_PASSWORD" \
      "$(jq -r '.gpu.functionIds // [] | join(",")' "$SITE")" "$(jq -r '.bulk.disk // empty' "$SITE")"
    cat "$SCRIPT_DIR/pve-install.sh"
} | "${SSH_CMD[@]}" root@"$TARGET_IP" "bash -s"


TOKEN_SECRET=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/terraform_token.txt")
HOMEPAGE_TOKEN=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/homepage_token.txt")
WAKE_TOKEN=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/wake_token.txt")
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"

jq -n \
    --arg proxmox_api_token_id "terraform-prov@pve!terraform-token" \
    --arg proxmox_api_token_secret "$TOKEN_SECRET" \
    --arg proxmox_datastore "local-lvm" \
    --argjson proxmox_ssh_port "$SSH_PORT" \
    --arg proxmox_ssh_user "root" \
    --arg proxmox_ssh_password "$ROOT_PASS" \
    '{
      proxmox_api_token_id: $proxmox_api_token_id,
      proxmox_api_token_secret: $proxmox_api_token_secret,
      proxmox_datastore: $proxmox_datastore,
      proxmox_ssh_port: $proxmox_ssh_port,
      proxmox_ssh_user: $proxmox_ssh_user,
      proxmox_ssh_password: (if $proxmox_ssh_password == "" then null else $proxmox_ssh_password end),
      proxmox_insecure: true
    }' > "$TFVARS_ENC_PATH"

sops --encrypt --in-place "$TFVARS_ENC_PATH"
rm -f "$ROOT_DIR/src/terraform.tfvars"

echo ">>> Storing the Homepage and on-demand wake Proxmox API tokens in secrets..."
secret_set proxmox-user "homepage@pve!homepage"
secret_set proxmox-pass "$HOMEPAGE_TOKEN"
secret_set proxmox-wake-token "wake@pve!ondemand=$WAKE_TOKEN"

echo ">>> INIT COMPLETE!"
echo ">>> External secrets (cloudflare-token, telegram-*, ...): fill the empty keys with 'sops src/secrets.json'"
echo ">>> Terraform connection vars: encrypted at src/terraform.tfvars.sops.json"
echo ">>> Next step: ./sync.sh"
