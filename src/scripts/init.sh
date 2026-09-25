#!/bin/bash
# Initialize homelab against an existing Proxmox VE server.
set -e

TARGET_IP=$1
SSH_PORT=22
API_PORT=8006

if [ -z "$TARGET_IP" ]; then
    echo "Usage: ./src/scripts/init.sh <PROXMOX_IP>"
    echo "Example: ./src/scripts/init.sh 192.168.178.200"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# check for required tools.
for tool in sops age-keygen jq sshpass; do
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
    SSH_CMD=(sshpass -p "$ROOT_PASS" ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes)
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
    # use the root password for the terraform user to avoid prompting twice. if using SSH keys
    if [ -n "$ROOT_PASS" ]; then
        PVE_TF_PASSWORD="$ROOT_PASS"
    else
        PVE_TF_PASSWORD=$(openssl rand -base64 24)
    fi
else
    PVE_TF_PASSWORD="$HOMELAB_PVE_TF_PASSWORD"
fi


if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUBLIC_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUBLIC_KEY="$(cat "$HOME/.ssh/id_rsa.pub")"
else
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "homelab@$(hostname)" >/dev/null
    SSH_PUBLIC_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
fi


# the age key belongs to the dotfiles repo, which is the source of truth for all key material.
AGE_KEY="$ROOT_DIR/secrets/age.txt"
AGE_KEY_SOURCE="${AGE_KEY_SOURCE:-$HOME/projects/arch-dotfiles/configs/secrets/age.txt}"
mkdir -p "$ROOT_DIR/secrets"
if [ ! -r "$AGE_KEY" ]; then
    if [ -r "$AGE_KEY_SOURCE" ]; then
        echo ">>> Linking the age key from $AGE_KEY_SOURCE"
        ln -sfn "$AGE_KEY_SOURCE" "$AGE_KEY"
    else
        echo ">>> Generating age key for sops-nix at $AGE_KEY_SOURCE..."
        mkdir -p "$(dirname "$AGE_KEY_SOURCE")"
        age-keygen -o "$AGE_KEY_SOURCE" 2>/dev/null
        chmod 600 "$AGE_KEY_SOURCE"
        ln -sfn "$AGE_KEY_SOURCE" "$AGE_KEY"
    fi
    AGE_PUB=$(age-keygen -y "$AGE_KEY")
    sed -i "s|AGE_PUBLIC_KEY_PLACEHOLDER|${AGE_PUB}|" "$ROOT_DIR/.sops.yaml"
fi


generate_secret() { openssl rand -base64 32 | tr -d '/+=' | head -c 48; }

SECRETS_FILE="$ROOT_DIR/src/secrets.json"

if [ ! -f "$SECRETS_FILE" ]; then
    echo ">>> Generating secrets..."
    WG_PRIVKEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)

    # generated locally where possible; external credentials are placeholders to fill
    jq -n \
      --arg wg "$WG_PRIVKEY" \
      --arg s1 "$(generate_secret)" --arg s2 "$(generate_secret)" --arg s3 "$(generate_secret)" \
      --arg s4 "$(generate_secret)" --arg s5 "$(generate_secret)" \
      --arg s9 "$(generate_secret)" \
      --arg s10 "$(generate_secret)" --arg s11 "$(generate_secret)" --arg s12 "base64:$(openssl rand -base64 32)" \
      '{
        "cloudflare-token": "ENTER_YOUR_CLOUDFLARE_API_TOKEN_HERE",
        "proxmox-api-token": "ENTER_USER@REALM!TOKENID=SECRET",
        "proxmox-user": "", "proxmox-pass": "",
        "lldap-admin-password": $s1, "lldap-jwt-secret": $s2, "authelia-admin-pass": $s3,
        "forgejo-admin-pass": $s4, "forgejo-oidc-secret": $s5,
        "restic-password": $s9, "minecraft-rcon-password": $s10,
        "firefly-db-password": $s11, "firefly-app-key": $s12,
        "crowdsec-bouncer-key": "", "attic-server-token": "", "attic-pull-token": "",
        "calendar-sources": "", "calendar-token": "", "kraken-api-key": "", "kraken-api-secret": "",
        "telegram-bot-token": "", "telegram-chat-id": "",
        "hermes-ssh-key": "", "hermes-llm-api-key": "",
        "wireguard-private-key": $wg
      }' > "$SECRETS_FILE"

    echo ">>> Encrypting secrets with sops..."
    sops --encrypt --in-place "$SECRETS_FILE"
    echo ">>> Secrets generated and encrypted."
    echo ">>> NOTE: fill the external tokens with: sops src/secrets.json"
fi

# add whatever the configs have grown since (and drop what they no longer read).
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
# second argument wires the LDAP realm; without the secret the step is skipped
LLDAP_BIND_PASSWORD=$(sops -d "$ROOT_DIR/src/secrets.json" 2>/dev/null \
  | jq -r '."lldap-admin-password" // empty')
"${SSH_CMD[@]}" root@"$TARGET_IP" "bash -s" < "$SCRIPT_DIR/pve-install.sh" \
  "$PVE_TF_PASSWORD" "$LLDAP_BIND_PASSWORD"


TOKEN_SECRET=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/terraform_token.txt")
HOMEPAGE_TOKEN=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/homepage_token.txt" 2>/dev/null || echo "")
TARGET_NODE_NAME=$("${SSH_CMD[@]}" root@"$TARGET_IP" "hostname")
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"

jq -n \
    --arg proxmox_api_token_id "terraform-prov@pve!terraform-token" \
    --arg proxmox_api_token_secret "$TOKEN_SECRET" \
    --arg proxmox_api_url "https://$TARGET_IP:$API_PORT/api2/json" \
    --arg proxmox_datastore "local-lvm" \
    --arg target_node "$TARGET_NODE_NAME" \
    --arg proxmox_ssh_host "$TARGET_IP" \
    --argjson proxmox_ssh_port "$SSH_PORT" \
    --arg proxmox_ssh_user "root" \
    --arg proxmox_ssh_password "$ROOT_PASS" \
    --arg ssh_public_key "$SSH_PUBLIC_KEY" \
    '{
      proxmox_api_token_id: $proxmox_api_token_id,
      proxmox_api_token_secret: $proxmox_api_token_secret,
      proxmox_api_url: $proxmox_api_url,
      proxmox_datastore: $proxmox_datastore,
      target_node: $target_node,
      proxmox_ssh_host: $proxmox_ssh_host,
      proxmox_ssh_port: $proxmox_ssh_port,
      proxmox_ssh_user: $proxmox_ssh_user,
      proxmox_ssh_password: (if $proxmox_ssh_password == "" then null else $proxmox_ssh_password end),
      proxmox_insecure: true,
      ssh_public_key: $ssh_public_key
    }' > "$TFVARS_ENC_PATH"

sops --encrypt --in-place "$TFVARS_ENC_PATH"
rm -f "$ROOT_DIR/src/terraform.tfvars"

# store Homepage PVE token in secrets.json for sops-nix
if [ -n "$HOMEPAGE_TOKEN" ]; then
    echo ">>> Storing Homepage Proxmox API token in secrets..."
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops set "$ROOT_DIR/src/secrets.json" \
        '["proxmox-user"]' '"homepage@pve!homepage"'
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops set "$ROOT_DIR/src/secrets.json" \
        '["proxmox-pass"]' "\"$HOMEPAGE_TOKEN\""
fi

echo ">>> INIT COMPLETE!"
echo ">>> WireGuard: keys auto-generated on first deploy. Run 'wg show' on the router to get the public key."
echo ">>> Cloudflare: edit token with 'sops src/secrets.yaml'"
echo ">>> Terraform connection vars: encrypted at src/terraform.tfvars.sops.json"
echo ">>> Next step: ./sync.sh"
