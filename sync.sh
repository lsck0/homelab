#!/bin/bash
# Sync the entire lab: apply Terraform, deploy NixOS.
# The only command you need to update the lab after changing config.
set -e

# Force bash as SHELL — OpenSSH uses $SHELL for ProxyCommand, and zsh can break it
export SHELL=/bin/bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_PATH="$ROOT_DIR/src/terraform.tfvars"
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"
AGE_KEY="$ROOT_DIR/secrets/age.txt"
ACTIVE_TFVARS_PATH=""
DEPLOY_FAILURE=0
CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

echo ">>> SYNCING HARDWARE + OS..."

# ── Helper functions ─────────────────────────────────────────

read_tfvar() {
  jq -r --arg key "$1" 'if has($key) and .[$key] != null then .[$key] else empty end' "$ACTIVE_TFVARS_PATH"
}

load_tfvars() {
  if [ -f "$TFVARS_PATH" ]; then
    ACTIVE_TFVARS_PATH="$TFVARS_PATH"
    return 0
  fi

  [ -f "$TFVARS_ENC_PATH" ] || { echo "ERROR: Missing tfvars. Run ./scripts/init.sh first."; return 1; }
  command -v sops >/dev/null 2>&1 || { echo "ERROR: sops required to decrypt $TFVARS_ENC_PATH"; return 1; }

  ACTIVE_TFVARS_PATH="$(mktemp --suffix=.tfvars.json)"
  CLEANUP_FILES+=("$ACTIVE_TFVARS_PATH")
  if [ -f "$AGE_KEY" ]; then
    SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  else
    sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  fi

  jq empty "$ACTIVE_TFVARS_PATH" >/dev/null 2>&1 || { echo "ERROR: Decrypted tfvars is not valid JSON."; return 1; }
}

wait_for_ssh() {
  local ip="$1" attempts="${2:-60}" sleep_s="${3:-5}"
  for _ in $(seq 1 "$attempts"); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${BASTION_SSHOPTS[@]}" "root@${ip}" "true" 2>/dev/null && return 0
    sleep "$sleep_s"
  done
  echo "ERROR: SSH not reachable at $ip"
  return 1
}

tf_apply_retry() {
  local dir="$1"; shift
  for i in $(seq 1 5); do
    terraform -chdir="$dir" apply -refresh=false -auto-approve -parallelism=3 "$@" && return 0
    echo "Terraform apply failed (attempt $i/5). Retrying..."
    sleep 5
  done
  echo "ERROR: Terraform apply failed after 5 attempts."
  return 1
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."

  if ! wait_for_ssh "$ip" 24 5; then return 1; fi

  local toplevel
  toplevel=$(nix build "$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel" \
    --extra-experimental-features "nix-command flakes" \
    --no-link --print-out-paths 2>&1 | tail -n1)
  [ -n "$toplevel" ] && [ -e "$toplevel" ] || { echo "ERROR: Failed to resolve closure for $name"; return 1; }

  # Skip if already up-to-date
  local current
  current=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@${ip}" "readlink -f /run/current-system" 2>/dev/null || true)
  if [ "$current" = "$toplevel" ]; then
    echo ">>> $name already up-to-date. Skipping."
    return 0
  fi

  # Push age key for sops-nix
  if [ -f "$AGE_KEY" ]; then
    ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "mkdir -p /var/lib/sops-nix && chmod 700 /var/lib/sops-nix" || return 1
    cat "$AGE_KEY" | ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "cat > /var/lib/sops-nix/key.txt && chmod 600 /var/lib/sops-nix/key.txt" || return 1
  fi

  # Copy closure and activate
  nix copy --extra-experimental-features "nix-command flakes" --to "ssh-ng://root@${ip}" "$toplevel" \
    || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set $toplevel && $toplevel/bin/switch-to-configuration boot && nohup sh -c 'sleep 1 && reboot' >/dev/null 2>&1 &"

  sleep 15
  wait_for_ssh "$ip" 60 5 || { echo "ERROR: VM did not come back after reboot!"; return 1; }
  echo ">>> $name deployed."
}

# ── Git ──────────────────────────────────────────────────────

git_auto_prepare() {
  [ "${HOMELAB_AUTO_GIT:-1}" = "1" ] || return 0
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

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
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  git -C "$ROOT_DIR" add -A
  git -C "$ROOT_DIR" diff --cached --quiet && { echo ">>> Auto git: no changes to commit."; return 0; }

  local last_subject next_gen commit_msg="Generation: 1"
  last_subject="$(git -C "$ROOT_DIR" show -s --format=%s 2>/dev/null || true)"
  if [[ "$last_subject" =~ Generation:\ ([0-9]+) ]]; then
    next_gen=$((BASH_REMATCH[1] + 1))
    commit_msg="Generation: ${next_gen}"
  fi

  echo ">>> Auto git: commit + push (${commit_msg})..."
  git -C "$ROOT_DIR" commit -m "${commit_msg}" || { echo "WARNING: git commit failed; continuing."; return 0; }
  git -C "$ROOT_DIR" push || echo "WARNING: git push failed; continuing."
}

# ── SSH transport ────────────────────────────────────────────

setup_ssh_transport() {
  PROXMOX_SSH_HOST="$(read_tfvar proxmox_ssh_host)"
  PROXMOX_SSH_PORT="$(read_tfvar proxmox_ssh_port)"
  PROXMOX_SSH_USER="$(read_tfvar proxmox_ssh_user)"
  PROXMOX_SSH_PASSWORD="$(read_tfvar proxmox_ssh_password)"
  : "${PROXMOX_SSH_HOST:=127.0.0.1}" "${PROXMOX_SSH_PORT:=22}" "${PROXMOX_SSH_USER:=root}"

  if [ -n "$PROXMOX_SSH_PASSWORD" ]; then
    SSH_CMD=(sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -p "$PROXMOX_SSH_PORT" -o StrictHostKeyChecking=accept-new)
    export SSHPASS="$PROXMOX_SSH_PASSWORD"
  else
    SSH_CMD=(ssh -p "$PROXMOX_SSH_PORT" -o StrictHostKeyChecking=accept-new)
  fi

  # Accept Proxmox host key
  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/known_hosts"
  ssh-keygen -R "[$PROXMOX_SSH_HOST]:$PROXMOX_SSH_PORT" >/dev/null 2>&1 || true
  ssh-keyscan -p "$PROXMOX_SSH_PORT" -H "$PROXMOX_SSH_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
    || { echo "ERROR: Could not fetch SSH host key for $PROXMOX_SSH_HOST:$PROXMOX_SSH_PORT"; exit 1; }

  # Router VM is the bastion for internal/external networks
  ROUTER_WAN_IP="192.168.178.29"

  SSH_CONFIG="$(mktemp --suffix=.ssh_config)"
  CLEANUP_FILES+=("$SSH_CONFIG")
  local ssh_bin="$(command -v ssh)"

  cat > "$SSH_CONFIG" <<EOF_SSH
Host proxmox-bastion
  HostName ${PROXMOX_SSH_HOST}
  Port ${PROXMOX_SSH_PORT}
  User ${PROXMOX_SSH_USER}
  StrictHostKeyChecking accept-new

Host 10.*
  ProxyCommand ${ssh_bin} -F ${SSH_CONFIG} -W %h:%p root@${ROUTER_WAN_IP}
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /dev/null
EOF_SSH

  BASTION_SSHOPTS=(-F "$SSH_CONFIG")
  export NIX_SSHOPTS="-F $SSH_CONFIG"
}

# ── VM IP discovery ──────────────────────────────────────────

discover_wan_ip() {
  local vm_id="$1" configured_ip="$2"

  # Try configured IP first
  if [ -n "$configured_ip" ] && [ "$configured_ip" != "dhcp" ]; then
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${BASTION_SSHOPTS[@]}" "root@${configured_ip}" "true" 2>/dev/null; then
      echo "$configured_ip"; return 0
    fi
    echo ">>> VM $vm_id not reachable at $configured_ip, scanning network..." >&2
  fi

  # Get MAC from Terraform state
  local mac
  mac=$(terraform -chdir="$ROOT_DIR/src" state show "module.instances.module.vm[\"${vm_id}\"].proxmox_virtual_environment_vm.this" 2>/dev/null \
    | awk '/network_device \{/{found=1} found && /mac_address/{gsub(/"/,"",$3); print tolower($3); exit}')
  [ -z "$mac" ] && { echo ">>> Could not determine MAC for VM $vm_id" >&2; return 1; }

  echo ">>> Looking for VM $vm_id MAC $mac..." >&2

  # Populate ARP table
  local subnet
  subnet=$(ip -4 addr show | awk '/inet.*brd/{print $4; exit}')
  [ -n "$subnet" ] && ping -b -c 2 -W 1 "$subnet" >/dev/null 2>&1 || true

  # Try arp-scan, then ARP table, then QEMU guest agent
  local ip=""
  if command -v arp-scan >/dev/null 2>&1; then
    ip=$(sudo arp-scan -l 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
  fi
  [ -z "$ip" ] && ip=$(ip -4 neigh show | grep -i "$mac" | awk '{print $1}' | head -1)
  [ -z "$ip" ] && ip=$("${SSH_CMD[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" \
    "pvesh get /nodes/\$(hostname)/qemu/${vm_id}/agent/network-get-interfaces --output-format json 2>/dev/null" \
    | python3 -c "
import sys,json
for r in json.load(sys.stdin).get('result',[]):
  if r['name']=='lo': continue
  for a in r.get('ip-addresses',[]):
    if a['ip-address-type']=='ipv4' and not a['ip-address'].startswith(('172.','169.254.')):
      print(a['ip-address']); sys.exit()
" 2>/dev/null)

  if [ -n "$ip" ]; then
    echo ">>> Found VM $vm_id at $ip" >&2
    echo "$ip"; return 0
  fi
  echo ">>> Could not discover IP for VM $vm_id" >&2
  return 1
}

# ── Main ─────────────────────────────────────────────────────

git_auto_prepare
load_tfvars
setup_ssh_transport

# Build all NixOS closures in background
echo ">>> Building all VM closures (background)..."
BUILD_LOG=$(mktemp --suffix=.build.log)
CLEANUP_FILES+=("$BUILD_LOG")
(
  rc=0
  for nix_file in "$ROOT_DIR"/src/instances/{1,2}[0-9][0-9]-*.nix \
                  "$ROOT_DIR"/src/instances/300-router.nix; do
    [ -f "$nix_file" ] || continue
    vm_name=$(basename "$nix_file" .nix)
    echo ">>> Building $vm_name..."
    nix build "$ROOT_DIR/src#nixosConfigurations.${vm_name}.config.system.build.toplevel" \
      --extra-experimental-features "nix-command flakes" --no-link 2>&1 \
      || { echo "ERROR: Failed to build $vm_name"; rc=1; }
  done
  exit $rc
) > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!

# Upload golden image if missing
if ! "${SSH_CMD[@]}" "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}" "test -f /var/lib/vz/template/iso/nixos.img" 2>/dev/null; then
  if [ -f "$ROOT_DIR/images/nixos.img" ]; then
    echo ">>> Uploading golden image to Proxmox..."
    scp -o StrictHostKeyChecking=accept-new "$ROOT_DIR/images/nixos.img" \
      "${PROXMOX_SSH_USER}@${PROXMOX_SSH_HOST}:/var/lib/vz/template/iso/nixos.img"
  else
    echo "ERROR: Golden image not found. Run: sudo nix build ./src#cloud-image"
    exit 1
  fi
fi

# Terraform
[ -d "$ROOT_DIR/src/.terraform" ] || terraform -chdir="$ROOT_DIR/src" init

TF_STAMP="$ROOT_DIR/src/.tf-last-apply"
if [ ! -f "$TF_STAMP" ] || find "$ROOT_DIR/src" -maxdepth 2 \( -name '*.tf' -o -name '*.tfvars*' \) -newer "$TF_STAMP" | grep -q .; then
  echo ">>> Terraform files changed. Applying..."
  tf_apply_retry "$ROOT_DIR/src" -var-file="$ACTIVE_TFVARS_PATH"
  touch "$TF_STAMP"
else
  echo ">>> No Terraform file changes since last apply. Skipping."
fi

echo ">>> Fetching VM IPs from Terraform..."
VM_IPS=$(terraform -chdir="$ROOT_DIR/src" output -raw vm_ips 2>/dev/null || echo "")

# ── Deploy router first ──────────────────────────────────────

configured_ip=$(echo "$VM_IPS" | grep "^300=" | cut -d= -f2 || true)
router_ip=$(discover_wan_ip "300" "$configured_ip" 2>/dev/null || true)

# Fallback: try internal bridge
if [ -z "$router_ip" ]; then
  echo ">>> Router not found on WAN, trying internal bridge (10.100.0.1)..."
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@10.100.0.1" "true" 2>/dev/null; then
    router_ip="10.100.0.1"
  fi
fi

if [ -n "$router_ip" ]; then
  deploy_nixos "300-router" "$router_ip" || { echo "WARNING: Failed to deploy router"; DEPLOY_FAILURE=1; }
else
  echo "WARNING: Could not reach router VM. Skipping."
  DEPLOY_FAILURE=1
fi

# Wait for bastion connectivity after router deploy
echo ">>> Waiting for router bastion..."
wait_for_ssh "$ROUTER_WAN_IP" 30 5 || { echo "ERROR: Router not reachable after deploy."; exit 1; }

echo ">>> Verifying bastion proxy to internal subnet..."
for _ in $(seq 1 12); do
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@10.100.0.100" "true" 2>/dev/null && break
  sleep 5
done

echo ">>> Verifying router DNS..."
for _ in $(seq 1 24); do
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${ROUTER_WAN_IP}" \
    "dig +short +timeout=2 ghcr.io @127.0.0.1 2>/dev/null | grep -q ." 2>/dev/null && break
  sleep 5
done

# ── Wait for builds ──────────────────────────────────────────

echo ">>> Waiting for background nix builds..."
if ! wait "$BUILD_PID"; then
  cat "$BUILD_LOG"
  echo "ERROR: Some builds failed. Aborting deployment."
  exit 1
fi
cat "$BUILD_LOG"
echo ">>> All builds complete."

# ── Deploy remaining VMs in parallel ─────────────────────────

MAX_PARALLEL="${HOMELAB_PARALLEL:-3}"
DEPLOY_PIDS=()
DEPLOY_NAMES=()

reap_finished() {
  local new_pids=() new_names=()
  for i in "${!DEPLOY_PIDS[@]}"; do
    if kill -0 "${DEPLOY_PIDS[$i]}" 2>/dev/null; then
      new_pids+=("${DEPLOY_PIDS[$i]}")
      new_names+=("${DEPLOY_NAMES[$i]}")
    else
      wait "${DEPLOY_PIDS[$i]}" || { echo "WARNING: Failed to deploy ${DEPLOY_NAMES[$i]}"; DEPLOY_FAILURE=1; }
    fi
  done
  DEPLOY_PIDS=("${new_pids[@]}")
  DEPLOY_NAMES=("${new_names[@]}")
}

echo ">>> Deploying VMs (up to $MAX_PARALLEL in parallel)..."
for nix_file in "$ROOT_DIR"/src/instances/{1,2}[0-9][0-9]-*.nix; do
  [ -f "$nix_file" ] || continue
  vm_name=$(basename "$nix_file" .nix)
  vm_id="${vm_name%%-*}"

  # Throttle
  while [ "${#DEPLOY_PIDS[@]}" -ge "$MAX_PARALLEL" ]; do
    reap_finished
    [ "${#DEPLOY_PIDS[@]}" -ge "$MAX_PARALLEL" ] && sleep 2
  done

  # Resolve IP
  ip=$(echo "$VM_IPS" | grep "^${vm_id}=" | cut -d= -f2 || true)
  [ -z "$ip" ] || [ "$ip" = "dhcp" ] && ip=$(discover_wan_ip "$vm_id" "dhcp" 2>/dev/null || true)

  if [ -z "$ip" ]; then
    echo ">>> WARNING: VM $vm_id has no IP. Skipping."
    continue
  fi

  deploy_nixos "$vm_name" "$ip" &
  DEPLOY_PIDS+=("$!")
  DEPLOY_NAMES+=("$vm_name")
done

# Wait for stragglers
for i in "${!DEPLOY_PIDS[@]}"; do
  wait "${DEPLOY_PIDS[$i]}" || { echo "WARNING: Failed to deploy ${DEPLOY_NAMES[$i]}"; DEPLOY_FAILURE=1; }
done

[ "$DEPLOY_FAILURE" -ne 0 ] && { echo "ERROR: One or more deployments failed."; exit 1; }

git_auto_commit_push
echo ">>> LAB IS FULLY SYNCHRONIZED"
