#!/bin/bash
# Initialize homelab against an existing Proxmox VE server.
# Usage: ./scripts/init.sh <PROXMOX_IP>
set -e

TARGET_IP=$1
SSH_PORT=22
API_PORT=8006

if [ -z "$TARGET_IP" ]; then
    echo "Usage: ./scripts/init.sh <PROXMOX_IP>"
    echo "Example: ./scripts/init.sh 192.168.178.200"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check for required tools.
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
    # Use the root password for the terraform user to avoid prompting twice.
    # If using SSH keys (blank root password), generate a random one since we use API token.
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


AGE_KEY="$ROOT_DIR/secrets/age.txt"
if [ ! -f "$AGE_KEY" ]; then
    echo ">>> Generating age key for sops-nix..."
    mkdir -p "$ROOT_DIR/secrets"
    age-keygen -o "$AGE_KEY" 2>/dev/null
    chmod 600 "$AGE_KEY"
    AGE_PUB=$(age-keygen -y "$AGE_KEY")
    sed -i "s|AGE_PUBLIC_KEY_PLACEHOLDER|${AGE_PUB}|" "$ROOT_DIR/.sops.yaml"
fi


generate_secret() { openssl rand -base64 32 | tr -d '/+=' | head -c 48; }

SECRETS_FILE="$ROOT_DIR/src/secrets.yaml"
AGE_PUB=$(age-keygen -y "$AGE_KEY")

if grep -q "CHANGE_ME" "$SECRETS_FILE" 2>/dev/null; then
    echo ">>> Generating secrets..."

    # Generate WireGuard keypair
    WG_PRIVKEY=$(wg genkey 2>/dev/null || openssl rand -base64 32)

    # Secrets grouped by VM, in VM ID order
    cat > "$SECRETS_FILE" <<SECRETS_EOF
# ── VM 100/200: Traefik (Cloudflare DNS challenge) ──
cloudflare-token: ENTER_YOUR_CLOUDFLARE_API_TOKEN_HERE

# ── VM 101: Authentik (SSO) ──
authentik-secret-key: $(generate_secret)
authentik-db-password: $(generate_secret)

# ── VM 101 → OIDC clients (sorted by consumer VM) ──
forgejo-oidc-secret: $(generate_secret)
vaultwarden-oidc-secret: $(generate_secret)
nextcloud-oidc-secret: $(generate_secret)

# ── VM 112: Nextcloud ──
nextcloud-admin-pass: $(generate_secret)

# ── VM 300: Router ──
wireguard-private-key: $WG_PRIVKEY
SECRETS_EOF

    echo ">>> Encrypting secrets with sops..."
    sops --encrypt --in-place "$SECRETS_FILE"
    echo ">>> Secrets generated and encrypted."
    echo ">>> NOTE: Edit cloudflare-token later with: sops src/secrets.yaml"
fi


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
"${SSH_CMD[@]}" root@"$TARGET_IP" "bash -s" < "$ROOT_DIR/scripts/pve-install.sh" "$PVE_TF_PASSWORD"


TOKEN_SECRET=$("${SSH_CMD[@]}" root@"$TARGET_IP" "cat /root/terraform_token.txt")
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

echo ">>> INIT COMPLETE!"
echo ">>> WireGuard: keys auto-generated on first deploy. Run 'wg show' on the router to get the public key."
echo ">>> Cloudflare: edit token with 'sops src/secrets.yaml'"
echo ">>> Terraform connection vars: encrypted at src/terraform.tfvars.sops.json"
echo ">>> Next step: ./sync.sh"
