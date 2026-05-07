#!/bin/bash
# Sync the entire lab: apply Terraform, deploy NixOS.
set -euo pipefail
export SHELL=/bin/bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_PATH="$ROOT_DIR/src/terraform.tfvars"
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"
AGE_KEY="$ROOT_DIR/secrets/age.txt"
ACTIVE_TFVARS_PATH=""
ROUTER_WAN_IP="192.168.178.29"
DEPLOY_FAILURE=0
CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

echo ">>> SYNCING HARDWARE + OS..."

# Abort if branch is behind upstream (unpulled changes exist)
git -C "$ROOT_DIR" fetch origin --quiet 2>/dev/null || true
BEHIND=$(git -C "$ROOT_DIR" rev-list "HEAD..@{u}" --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
  echo "ERROR: Branch is $BEHIND commit(s) behind upstream. Run 'git pull' first."
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────

read_tfvar() {
  jq -r --arg k "$1" 'if has($k) and .[$k] != null then .[$k] else empty end' "$ACTIVE_TFVARS_PATH"
}

load_tfvars() {
  if [ -f "$TFVARS_PATH" ]; then
    ACTIVE_TFVARS_PATH="$TFVARS_PATH"; return 0
  fi
  [ -f "$TFVARS_ENC_PATH" ] || { echo "ERROR: Missing tfvars. Run ./scripts/init.sh first."; exit 1; }
  command -v sops >/dev/null || { echo "ERROR: sops not installed."; exit 1; }
  ACTIVE_TFVARS_PATH="$(mktemp --suffix=.tfvars.json)"
  CLEANUP_FILES+=("$ACTIVE_TFVARS_PATH")
  SOPS_AGE_KEY_FILE="$AGE_KEY" sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH" \
    || sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
  jq empty "$ACTIVE_TFVARS_PATH" >/dev/null || { echo "ERROR: Decrypted tfvars is not valid JSON."; exit 1; }
}

wait_for_ssh() {
  local ip="$1" attempts="${2:-60}" interval="${3:-5}"
  for _ in $(seq 1 "$attempts"); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 "${BASTION_SSHOPTS[@]}" "root@${ip}" true 2>/dev/null && return 0
    sleep "$interval"
  done
  echo "ERROR: SSH not reachable at $ip"; return 1
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."
  wait_for_ssh "$ip" 60 5 || return 1

  local toplevel
  toplevel=$(nix build "$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel" \
    --extra-experimental-features "nix-command flakes" --no-link --print-out-paths 2>&1 | tail -n1)
  [ -n "$toplevel" ] && [ -e "$toplevel" ] || { echo "ERROR: Build failed for $name"; return 1; }

  local current
  current=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "readlink -f /run/current-system" 2>/dev/null || true)
  [ "$current" = "$toplevel" ] && { echo ">>> $name already up-to-date. Skipping."; return 0; }

  if [ -f "$AGE_KEY" ]; then
    ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "mkdir -p /var/lib/sops-nix && chmod 700 /var/lib/sops-nix" || return 1
    cat "$AGE_KEY" | ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
      "cat > /var/lib/sops-nix/key.txt && chmod 600 /var/lib/sops-nix/key.txt" || return 1
  fi

  nix copy --extra-experimental-features "nix-command flakes" --to "ssh-ng://root@${ip}" "$toplevel" \
    || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  # Use 'switch' — activates config in-place, restarts changed services, no reboot needed.
  # Reboot manually only when kernel changes (rare).
  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${toplevel}' \
     && '${toplevel}/bin/switch-to-configuration' switch"
  echo ">>> $name deployed."
}

# ── Main ──────────────────────────────────────────────────────

load_tfvars

# Git pull (skip if local changes)
if git -C "$ROOT_DIR" diff --quiet && git -C "$ROOT_DIR" diff --cached --quiet; then
  git -C "$ROOT_DIR" pull --rebase 2>/dev/null || echo "WARNING: git pull failed."
fi

# SSH transport
PROXMOX_SSH_HOST="$(read_tfvar proxmox_ssh_host)"; : "${PROXMOX_SSH_HOST:=127.0.0.1}"
PROXMOX_SSH_PORT="$(read_tfvar proxmox_ssh_port)"; : "${PROXMOX_SSH_PORT:=22}"
PROXMOX_SSH_USER="$(read_tfvar proxmox_ssh_user)"; : "${PROXMOX_SSH_USER:=root}"
PROXMOX_SSH_PASSWORD="$(read_tfvar proxmox_ssh_password)"

if [ -n "$PROXMOX_SSH_PASSWORD" ]; then
  SSH_CMD=(sshpass -p "$PROXMOX_SSH_PASSWORD" ssh -p "$PROXMOX_SSH_PORT" -o StrictHostKeyChecking=accept-new)
  export SSHPASS="$PROXMOX_SSH_PASSWORD"
else
  SSH_CMD=(ssh -p "$PROXMOX_SSH_PORT" -o StrictHostKeyChecking=accept-new)
fi

mkdir -p "$HOME/.ssh" && touch "$HOME/.ssh/known_hosts"
ssh-keygen -R "[$PROXMOX_SSH_HOST]:$PROXMOX_SSH_PORT" >/dev/null 2>&1 || true
ssh-keyscan -p "$PROXMOX_SSH_PORT" -H "$PROXMOX_SSH_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
  || { echo "ERROR: Cannot reach Proxmox at $PROXMOX_SSH_HOST:$PROXMOX_SSH_PORT"; exit 1; }

SSH_CONFIG="$(mktemp --suffix=.ssh_config)"; CLEANUP_FILES+=("$SSH_CONFIG")
cat > "$SSH_CONFIG" <<EOF
Host 10.*
  ProxyCommand $(command -v ssh) -F $SSH_CONFIG -o StrictHostKeyChecking=accept-new -W %h:%p root@$ROUTER_WAN_IP
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /dev/null
EOF
BASTION_SSHOPTS=(-F "$SSH_CONFIG")
export NIX_SSHOPTS="-F $SSH_CONFIG"

# SSH key — generate if missing, push to all VMs via QEMU agent
[ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "homelab@$(hostname)" >/dev/null
PUBKEY=$(cat "$HOME/.ssh/id_ed25519.pub")
PROXMOX_API_TOKEN_ID="$(read_tfvar proxmox_api_token_id)"
PROXMOX_API_TOKEN_SECRET="$(read_tfvar proxmox_api_token_secret)"
PROXMOX_NODE="$(read_tfvar target_node)"
PVE_API="https://$PROXMOX_SSH_HOST:8006/api2/json"
PVE_AUTH="Authorization: PVEAPIToken=$PROXMOX_API_TOKEN_ID=$PROXMOX_API_TOKEN_SECRET"

if [ -n "$PROXMOX_API_TOKEN_ID" ] && [ -n "$PROXMOX_API_TOKEN_SECRET" ]; then
  echo ">>> Pushing SSH key to all running VMs..."
  VMIDS=$(curl -sk "$PVE_API/nodes/$PROXMOX_NODE/qemu" -H "$PVE_AUTH" \
    | jq -r '.data[] | select(.status=="running") | .vmid' 2>/dev/null || true)
  for vmid in $VMIDS; do
    payload=$(jq -cn --arg k "$PUBKEY" \
      '{"command":["/bin/sh","-c","mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \($k) > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && systemctl disable --now cloud-init 2>/dev/null; true"]}')
    curl -sk -X POST "$PVE_API/nodes/$PROXMOX_NODE/qemu/$vmid/agent/exec" \
      -H "$PVE_AUTH" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
  done
  sleep 3

  # Vzdump backup jobs — always PUT (upsert: creates or updates schedule/settings)
  for job_spec in "homelab-daily|105,207|00:00|3" "homelab-weekly|105,207|Mon 00:00|2" "homelab-monthly|105,207|*-*-01 00:00|1"; do
    IFS='|' read -r jid jvms jsched jkeep <<< "$job_spec"
    # Try update first; if 404, create
    RESULT=$(curl -sk -X PUT "$PVE_API/cluster/backup/$jid" -H "$PVE_AUTH" \
      --data-urlencode "vmid=$jvms" --data-urlencode "schedule=$jsched" \
      --data-urlencode "storage=local" --data-urlencode "mode=snapshot" --data-urlencode "compress=zstd" \
      --data-urlencode "maxfiles=$jkeep" --data-urlencode "enabled=1" --data-urlencode "node=$PROXMOX_NODE" 2>&1)
    if echo "$RESULT" | grep -q '"errors"'; then
      RESULT=$(curl -sk -X POST "$PVE_API/cluster/backup" -H "$PVE_AUTH" \
        --data-urlencode "id=$jid" --data-urlencode "vmid=$jvms" --data-urlencode "schedule=$jsched" \
        --data-urlencode "storage=local" --data-urlencode "mode=snapshot" --data-urlencode "compress=zstd" \
        --data-urlencode "maxfiles=$jkeep" --data-urlencode "enabled=1" --data-urlencode "node=$PROXMOX_NODE" 2>&1)
      echo "$RESULT" | grep -q '"errors"' && echo "WARNING: Failed to upsert vzdump job $jid" || echo ">>> Created vzdump job $jid"
    else
      echo ">>> Vzdump job $jid: schedule=$jsched maxfiles=$jkeep"
    fi
  done
fi

# Proxmox host power savings (idempotent, best-effort)
"${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > "$f" 2>/dev/null; done
   hdparm -S 241 /dev/sda 2>/dev/null || true   # spin down unused HDD after ~30min
   echo ">>> Proxmox: CPU powersave, HDD spin-down 30min"' \
  2>/dev/null || true

# Golden image
if ! "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f /var/lib/vz/template/iso/nixos.img" 2>/dev/null; then
  [ -f "$ROOT_DIR/images/nixos.img" ] || { echo "ERROR: Golden image missing. Run: sudo nix build ./src#cloud-image"; exit 1; }
  echo ">>> Uploading golden image..."
  scp -o StrictHostKeyChecking=accept-new "$ROOT_DIR/images/nixos.img" \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:/var/lib/vz/template/iso/nixos.img"
fi

# Terraform
[ -d "$ROOT_DIR/src/.terraform" ] || terraform -chdir="$ROOT_DIR/src" init
TF_STAMP="$ROOT_DIR/src/.tf-last-apply"
if [ ! -f "$TF_STAMP" ] || find "$ROOT_DIR/src" -maxdepth 2 \( -name '*.tf' -o -name '*.tfvars*' \) -newer "$TF_STAMP" | grep -q .; then
  echo ">>> Terraform: applying..."
  for i in $(seq 1 5); do
    terraform -chdir="$ROOT_DIR/src" apply -refresh=false -auto-approve -parallelism=3 \
      -var-file="$ACTIVE_TFVARS_PATH" && break
    [ "$i" -eq 5 ] && { echo "ERROR: Terraform failed after 5 attempts."; exit 1; }
    echo "Retrying ($i/5)..."; sleep 5
  done
  touch "$TF_STAMP"
else
  echo ">>> Terraform: no changes."
fi

VM_IPS=$(terraform -chdir="$ROOT_DIR/src" output -raw vm_ips 2>/dev/null || echo "")
DISABLED_VMS=$(terraform -chdir="$ROOT_DIR/src" output -raw disabled_vms 2>/dev/null || echo "")
[ -n "$DISABLED_VMS" ] && echo ">>> Disabled VMs: $(echo "$DISABLED_VMS" | tr '\n' ' ')"

# Build all enabled closures in parallel
echo ">>> Building all VM closures (parallel)..."
BUILD_LOG=$(mktemp --suffix=.build.log); CLEANUP_FILES+=("$BUILD_LOG")
(
  rc=0; pids=(); names=()
  for f in "$ROOT_DIR"/src/instances/{1,2}[0-9][0-9]-*.nix "$ROOT_DIR"/src/instances/300-router.nix; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .nix); vm_id="${name%%-*}"
    if echo "$DISABLED_VMS" | grep -qx "$vm_id"; then
      echo ">>> Skipping build for $name (disabled)"; continue
    fi
    echo ">>> Building $name..."
    (nix build "$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel" \
      --extra-experimental-features "nix-command flakes" --no-link 2>&1 \
      || echo "ERROR: Build failed for $name") &
    pids+=($!); names+=("$name")
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { echo "ERROR: Build failed for ${names[$i]}"; rc=1; }
  done
  exit $rc
) > "$BUILD_LOG" 2>&1 &
BUILD_PID=$!

# Deploy router first (it's the SSH bastion for all other VMs)
echo ">>> Deploying 300-router to $ROUTER_WAN_IP..."
deploy_nixos "300-router" "$ROUTER_WAN_IP" || { echo "WARNING: Router deploy failed"; DEPLOY_FAILURE=1; }

if [ "$DEPLOY_FAILURE" -eq 0 ]; then
  echo ">>> Waiting for router bastion..."
  wait_for_ssh "$ROUTER_WAN_IP" 30 5 || { echo "ERROR: Router unreachable after deploy."; exit 1; }

  echo ">>> Verifying bastion → internal subnet..."
  for _ in $(seq 1 12); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" root@10.100.0.100 true 2>/dev/null && break
    sleep 5
  done

  echo ">>> Verifying router DNS..."
  for _ in $(seq 1 24); do
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$ROUTER_WAN_IP" \
      "dig +short +timeout=2 ghcr.io @127.0.0.1 2>/dev/null | grep -q ." 2>/dev/null && break
    sleep 5
  done
fi

# Wait for builds
echo ">>> Waiting for builds..."
if ! wait "$BUILD_PID"; then
  cat "$BUILD_LOG"; echo "ERROR: Build failed."; exit 1
fi
cat "$BUILD_LOG"
echo ">>> All builds complete."

# Deploy all other VMs (parallel, max 3)
MAX_PARALLEL="${HOMELAB_PARALLEL:-6}"
DEPLOY_PIDS=(); DEPLOY_NAMES=()

reap() {
  local new_pids=() new_names=()
  for i in "${!DEPLOY_PIDS[@]}"; do
    if kill -0 "${DEPLOY_PIDS[$i]}" 2>/dev/null; then
      new_pids+=("${DEPLOY_PIDS[$i]}"); new_names+=("${DEPLOY_NAMES[$i]}")
    else
      wait "${DEPLOY_PIDS[$i]}" || { echo "WARNING: Failed to deploy ${DEPLOY_NAMES[$i]}"; DEPLOY_FAILURE=1; }
    fi
  done
  DEPLOY_PIDS=("${new_pids[@]}"); DEPLOY_NAMES=("${new_names[@]}")
}

echo ">>> Deploying VMs (up to $MAX_PARALLEL in parallel)..."
for f in "$ROOT_DIR"/src/instances/{1,2}[0-9][0-9]-*.nix; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .nix); vm_id="${name%%-*}"
  if echo "$DISABLED_VMS" | grep -qx "$vm_id"; then
    echo ">>> Skipping $name (disabled)"; continue
  fi
  ip=$(echo "$VM_IPS" | grep "^${vm_id}=" | cut -d= -f2 || true)
  [ -z "$ip" ] && { echo ">>> WARNING: No IP for $name, skipping."; continue; }

  while [ "${#DEPLOY_PIDS[@]}" -ge "$MAX_PARALLEL" ]; do
    reap; [ "${#DEPLOY_PIDS[@]}" -ge "$MAX_PARALLEL" ] && sleep 2
  done

  deploy_nixos "$name" "$ip" &
  DEPLOY_PIDS+=("$!"); DEPLOY_NAMES+=("$name")
done

for i in "${!DEPLOY_PIDS[@]}"; do
  wait "${DEPLOY_PIDS[$i]}" || { echo "WARNING: Failed to deploy ${DEPLOY_NAMES[$i]}"; DEPLOY_FAILURE=1; }
done

# Git commit + push (always, even on partial failure)
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" add -A
  if ! git -C "$ROOT_DIR" diff --cached --quiet; then
    last=$(git -C "$ROOT_DIR" show -s --format=%s 2>/dev/null || true)
    next=1
    [[ "$last" =~ Generation:\ ([0-9]+) ]] && next=$((BASH_REMATCH[1] + 1))
    echo ">>> Git: committing Generation: $next"
    git -C "$ROOT_DIR" commit -m "Generation: $next"
    git -C "$ROOT_DIR" push || echo "WARNING: git push failed."
  fi
fi

[ "$DEPLOY_FAILURE" -ne 0 ] && { echo "ERROR: One or more deployments failed."; exit 1; }
echo ">>> LAB IS FULLY SYNCHRONIZED"
