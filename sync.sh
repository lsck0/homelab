#!/bin/bash
# Sync the entire lab: apply Terraform, deploy NixOS.
# The only command you need to update the lab after changing config.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
TFVARS_PATH="$ROOT_DIR/src/terraform.tfvars"
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"
ACTIVE_TFVARS_PATH=""


echo ">>> SYNCING HARDWARE + OS..."


wait_for_http() {
  local url="$1" label="$2" attempts="${3:-60}" sleep_s="${4:-2}"
  for _ in $(seq 1 "$attempts"); do
    if curl -k -sS --connect-timeout 3 "$url" >/dev/null 2>&1; then return 0; fi
    sleep "$sleep_s"
  done
  echo "ERROR: $label not reachable at $url"
  return 1
}

tf_apply_retry() {
  local dir="$1"; shift
  local attempts=5 rc=0
  for i in $(seq 1 "$attempts"); do
    rc=0
    terraform -chdir="$dir" apply -parallelism=1 -auto-approve "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo "Terraform apply failed (attempt $i/$attempts). Retrying..."
    sleep 5
  done
  echo "ERROR: Terraform apply failed after $attempts attempts."
  return 1
}

read_tfvar() {
  local key="$1"
  jq -r --arg key "$key" 'if has($key) and .[$key] != null then .[$key] else empty end' "$ACTIVE_TFVARS_PATH"
}

load_tfvars() {
  if [ -f "$TFVARS_PATH" ]; then
    ACTIVE_TFVARS_PATH="$TFVARS_PATH"
    return 0
  fi

  if [ ! -f "$TFVARS_ENC_PATH" ]; then
    echo "ERROR: Missing tfvars. Run ./scripts/init.sh first."
    return 1
  fi

  if ! command -v sops >/dev/null 2>&1; then
    echo "ERROR: sops required to decrypt $TFVARS_ENC_PATH"
    return 1
  fi

  ACTIVE_TFVARS_PATH="$(mktemp --suffix=.tfvars.json)"
  if [ -f "$ROOT_DIR/keys/age.txt" ]; then
    SOPS_AGE_KEY_FILE="$ROOT_DIR/keys/age.txt" sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  else
    sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  fi
  trap 'rm -f "$ACTIVE_TFVARS_PATH"' EXIT

  if ! jq empty "$ACTIVE_TFVARS_PATH" >/dev/null 2>&1; then
    echo "ERROR: Decrypted tfvars is not valid JSON."
    return 1
  fi
}

git_auto_prepare() {
  [ "${HOMELAB_AUTO_GIT:-1}" = "1" ] || return 0

  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
    echo ">>> Skipping git pull (local changes detected)."
    return 0
  fi

  echo ">>> Git sync: pull + submodules..."
  git -C "$ROOT_DIR" pull --rebase || echo "WARNING: git pull failed; continuing."
  git -C "$ROOT_DIR" submodule update --init --recursive || echo "WARNING: submodule update failed; continuing."
}

git_auto_commit_push() {
  [ "${HOMELAB_AUTO_GIT:-1}" = "1" ] || return 0

  if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  git -C "$ROOT_DIR" add -A
  if git -C "$ROOT_DIR" diff --cached --quiet; then
    echo ">>> Auto git: no changes to commit."
    return 0
  fi

  local last_subject commit_msg next_gen
  last_subject="$(git -C "$ROOT_DIR" show -s --format=%s 2>/dev/null || true)"
  commit_msg="Generation: 1"
  if [[ "$last_subject" =~ Generation:\ ([0-9]+) ]]; then
    next_gen=$((BASH_REMATCH[1] + 1))
    commit_msg="Generation: ${next_gen}"
  fi

  echo ">>> Auto git: commit + push (${commit_msg})..."
  git -C "$ROOT_DIR" commit -m "${commit_msg}" || { echo "WARNING: git commit failed; continuing."; return 0; }
  git -C "$ROOT_DIR" push || echo "WARNING: git push failed; continuing."
}

setup_ssh_transport() {
  PROXMOX_SSH_HOST="$(read_tfvar proxmox_ssh_host)"
  PROXMOX_SSH_PORT="$(read_tfvar proxmox_ssh_port)"
  PROXMOX_SSH_USER="$(read_tfvar proxmox_ssh_user)"
  PROXMOX_SSH_PASSWORD="$(read_tfvar proxmox_ssh_password)"

  [ -n "$PROXMOX_SSH_HOST" ] || PROXMOX_SSH_HOST="127.0.0.1"
  [ -n "$PROXMOX_SSH_PORT" ] || PROXMOX_SSH_PORT="22"
  [ -n "$PROXMOX_SSH_USER" ] || PROXMOX_SSH_USER="root"

  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/known_hosts"
  ssh-keygen -R "[$PROXMOX_SSH_HOST]:$PROXMOX_SSH_PORT" >/dev/null 2>&1 || true
  if ! ssh-keyscan -p "$PROXMOX_SSH_PORT" -H "$PROXMOX_SSH_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null; then
    echo "ERROR: Could not fetch SSH host key for $PROXMOX_SSH_HOST:$PROXMOX_SSH_PORT"
    exit 1
  fi

  if [ -n "$PROXMOX_SSH_PASSWORD" ]; then
  export SSHPASS="$PROXMOX_SSH_PASSWORD"
fi

cat >> "$SSH_CONFIG" <<EOF_SSH
Host 10.*
  ProxyJump root@192.168.178.29
EOF_SSH

BASTION_SSHOPTS=(-F "$SSH_CONFIG")
export NIX_SSHOPTS="-F $SSH_CONFIG"
}

AGE_KEY="$ROOT_DIR/keys/age.txt"

wait_for_ssh() {
  local ip="$1" attempts="${2:-60}" sleep_s="${3:-5}"
  for _ in $(seq 1 "$attempts"); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${BASTION_SSHOPTS[@]}" "root@${ip}" "true"; then return 0; fi
    sleep "$sleep_s"
  done
  echo "ERROR: SSH not reachable at $ip"
  return 1
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."

  echo ">>> Waiting for SSH on $ip..."
  if ! wait_for_ssh "$ip" 6 5; then return 1; fi

  local result
  if ! result=$(nix build "$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel" \
    --extra-experimental-features "nix-command flakes" \
    --no-link --print-out-paths 2>&1); then
    echo "ERROR: Failed to build $name"
    echo "$result"
    return 1
  fi
  local toplevel
  toplevel=$(echo "$result" | tail -n1)

  if [ -f "$AGE_KEY" ]; then
    ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "mkdir -p /var/lib/sops-nix && chmod 700 /var/lib/sops-nix" || return 1
    cat "$AGE_KEY" | ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "cat > /var/lib/sops-nix/key.txt && chmod 600 /var/lib/sops-nix/key.txt" || return 1
  fi

  nix copy --extra-experimental-features "nix-command flakes" \
      --to "ssh://root@${ip}?ssh-key=$HOME/.ssh/id_ed25519" \
      "$toplevel" 2>/dev/null \
  || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  # Run the switch command in the background detached from SSH via systemd-run, because network restarts
  # (e.g. dhcpcd) will drop the SSH connection and SIGHUP the switch process mid-way.
  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set $toplevel && systemd-run --unit=nixos-switch-$name $toplevel/bin/switch-to-configuration switch"

  echo ">>> Waiting for VM to apply configuration and return online..."
  sleep 10
  if ! wait_for_ssh "$ip" 30 5; then
    echo "ERROR: VM did not come back online after configuration switch!"
    return 1
  fi
  
  echo ">>> $name deployed."
}

echo ">>> Fetching VM IPs from Terraform..."
VM_IPS=$(terraform -chdir="$ROOT_DIR/src" output -raw vm_ips 2>/dev/null || echo "")

# Ensure the Proxmox host can route to the internal/external networks to act as a bastion.

# Deploy the router first (other VMs depend on it for connectivity)
# The router may have a DHCP IP (golden image) instead of its configured static IP.
# Discover its actual IP by MAC address from the local network.
discover_wan_ip() {
  local vm_id="$1"
  local configured_ip="$2"

  # Try configured IP first
  if [ -n "$configured_ip" ] && [ "$configured_ip" != "dhcp" ]; then
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${BASTION_SSHOPTS[@]}" "root@${configured_ip}" "true" 2>/dev/null; then
      echo "$configured_ip"
      return 0
    fi
    echo ">>> VM $vm_id not reachable at $configured_ip, scanning network..." >&2
  else
    echo ">>> VM $vm_id configured with DHCP, scanning network..." >&2
  fi

  # Get the WAN MAC from Terraform state
  local mac
  mac=$(terraform -chdir="$ROOT_DIR/src" state show "module.vms.module.vm_${vm_id}.module.vm.proxmox_virtual_environment_vm.this" 2>/dev/null \
    | awk '/network_device \{/{found=1} found && /mac_address/{gsub(/"/,"",$3); print tolower($3); exit}')

  if [ -z "$mac" ]; then
    echo ">>> Could not determine MAC address for VM $vm_id" >&2
    return 1
  fi

  echo ">>> Looking for VM $vm_id MAC $mac on local network..." >&2

  # Ping broadcast to populate ARP table, then check
  local subnet
  subnet=$(ip -4 addr show | awk '/inet.*brd/{print $4; exit}')
  if [ -n "$subnet" ]; then
    ping -b -c 2 -W 1 "$subnet" >/dev/null 2>&1 || true
  fi

  # Also try arp-scan if available, otherwise fall back to ARP table
  local discovered_ip=""
  if command -v arp-scan >/dev/null 2>&1; then
    discovered_ip=$(sudo arp-scan -l 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
  fi

  if [ -z "$discovered_ip" ]; then
    discovered_ip=$(ip -4 neigh show | grep -i "$mac" | awk '{print $1}' | head -1)
  fi

  if [ -z "$discovered_ip" ]; then
    # Last resort: ask Proxmox for the VM's IP via QEMU guest agent
    discovered_ip=$("${SSH_CMD[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" \
      "pvesh get /nodes/\$(hostname)/qemu/${vm_id}/agent/network-get-interfaces --output-format json 2>/dev/null" \
      | python3 -c "import sys,json; [print(a['ip-address']) for r in json.load(sys.stdin)['result'] if r['name']!='lo' for a in r.get('ip-addresses',[]) if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith('172.') and not a['ip-address'].startswith('169.254')]" 2>/dev/null \
      | head -1)
  fi

  if [ -n "$discovered_ip" ]; then
    echo ">>> Found VM $vm_id at $discovered_ip" >&2
    echo "$discovered_ip"
    return 0
  fi

  echo ">>> Could not discover IP for VM $vm_id" >&2
  return 1
}

discover_vm_ip() {
  local vm_id="$1"
  "${SSH_CMD[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" \
    "pvesh get /nodes/\$(hostname)/qemu/${vm_id}/agent/network-get-interfaces --output-format json 2>/dev/null" \
    | python3 -c "import json,sys; data=json.load(sys.stdin).get('result',[]); ips=[]; [ips.append(a['ip-address']) for iface in data for a in iface.get('ip-addresses',[]) if a.get('ip-address-type')=='ipv4' and not a['ip-address'].startswith('127.') and not a['ip-address'].startswith('169.254.')]; print(ips[0] if ips else '')" 2>/dev/null \
    | head -1
}

for nix_file in "$ROOT_DIR"/src/instances/300-router.nix; do
  [ -f "$nix_file" ] || continue
  vm_name=$(basename "$nix_file" .nix)
  configured_ip=$(echo "$VM_IPS" | grep "^300=" | cut -d= -f2 || true)
  ip=$(discover_wan_ip "300" "$configured_ip") || true

  if [ -z "$ip" ]; then
    # Fallback: deploy via internal interface if the router is reachable there
    echo ">>> Router not found on WAN, trying internal bridge (10.100.0.1)..."
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
         "${BASTION_SSHOPTS[@]}" \
         "root@10.100.0.1" "true" 2>/dev/null; then
      ip="10.100.0.1"
      echo ">>> Router reachable at $ip via Proxmox bridge"
    fi
  fi

  if [ -n "$ip" ]; then
    if ! deploy_nixos "$vm_name" "$ip"; then
      echo "WARNING: Failed to deploy router"
      DEPLOY_FAILURE=1
    fi
  else
    echo "WARNING: Could not reach router VM. Skipping."
    DEPLOY_FAILURE=1
  fi
done

# Deploy remaining VMs
for nix_file in "$ROOT_DIR"/src/instances/301-grafana.nix \
                "$ROOT_DIR"/src/instances/1[0-9][0-9]-*.nix \
                "$ROOT_DIR"/src/instances/2[0-9][0-9]-*.nix; do
  [ -f "$nix_file" ] || continue
  vm_name=$(basename "$nix_file" .nix)
  vm_id="${vm_name%%-*}"

  ip=$(echo "$VM_IPS" | grep "^${vm_id}=" | cut -d= -f2 || true)
  if [ -z "$ip" ] || [ "$ip" = "dhcp" ]; then
    ip=$(discover_wan_ip "$vm_id" "dhcp" || true)
    if [ -z "$ip" ]; then
      ip=$(discover_vm_ip "$vm_id" || true)
    fi
  fi

  if [ -z "$ip" ]; then
    echo ">>> WARNING: VM $vm_id has no Terraform output. Skipping."
    continue
  fi

  if ! deploy_nixos "$vm_name" "$ip"; then
    echo "WARNING: Failed to deploy $vm_name"
    continue
  fi
done

if [ "$DEPLOY_FAILURE" -ne 0 ]; then
  echo "ERROR: One or more deployments failed."
  exit 1
fi

git_auto_commit_push
echo ">>> LAB IS FULLY SYNCHRONIZED"
