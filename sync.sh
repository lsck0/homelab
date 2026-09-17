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

# abort if branch is behind upstream (unpulled changes exist)
git -C "$ROOT_DIR" fetch origin --quiet 2>/dev/null || true
BEHIND=$(git -C "$ROOT_DIR" rev-list "HEAD..@{u}" --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
  echo "ERROR: Branch is $BEHIND commit(s) behind upstream. Run 'git pull' first."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
read_tfvar() {
  jq -r --arg k "$1" 'if has($k) and .[$k] != null then .[$k] else empty end' "$ACTIVE_TFVARS_PATH"
}

load_tfvars() {
  if [ -f "$TFVARS_PATH" ]; then
    ACTIVE_TFVARS_PATH="$TFVARS_PATH"; return 0
  fi
  [ -f "$TFVARS_ENC_PATH" ] || { echo "ERROR: Missing tfvars. Run ./src/scripts/init.sh first."; exit 1; }
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

  # --no-check-sigs: the closures are built locally and pushed to our own VMs,
  # so they are unsigned; without this the remote daemon rejects them with
  # "cannot add path ... because it lacks a signature by a trusted key".
  nix copy --extra-experimental-features "nix-command flakes" --no-check-sigs --to "ssh-ng://root@${ip}" "$toplevel" \
    || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  # use 'switch', activates config in-place, restarts changed services, no reboot needed.
  # reboot manually only when kernel changes (rare).
  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${toplevel}' \
     && '${toplevel}/bin/switch-to-configuration' switch"
  echo ">>> $name deployed."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
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

# the router is a bastion for the 10.x subnets, but when the deployer already
# has a route to them (e.g. the LAN gateway routes 10.100.0.0/24 to the router),
# jumping through the router's single SSH -W forward just serializes every
# closure copy through one powersave CPU. Probe a directly-routed hop first and
# only fall back to the ProxyCommand when the subnet is not reachable directly.
if timeout 4 bash -c "echo > /dev/tcp/10.100.0.100/22" 2>/dev/null; then
  echo ">>> Internal subnet directly routable: deploying without the router bastion."
  cat > "$SSH_CONFIG" <<EOF
Host 10.*
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /dev/null
EOF
else
  echo ">>> Internal subnet not directly routable: deploying through the router bastion."
  cat > "$SSH_CONFIG" <<EOF
Host 10.*
  ProxyCommand $(command -v ssh) -F $SSH_CONFIG -o StrictHostKeyChecking=accept-new -W %h:%p root@$ROUTER_WAN_IP
  StrictHostKeyChecking accept-new
  UserKnownHostsFile /dev/null
EOF
fi
BASTION_SSHOPTS=(-F "$SSH_CONFIG")
export NIX_SSHOPTS="-F $SSH_CONFIG"

# SSH key: generate if missing, push to all VMs via QEMU agent
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

  # whole-VM vzdump jobs used to dump vm-108 (750 GB NAS disk) and vm-208 to
  # `local`, the host's root disk, daily/weekly/monthly: enough to fill it.
  # NAS data is backed up by Kopia (vm-106) and VM configs are declarative, so
  # remove the jobs. Existing dump files are NOT deleted here.
  for jid in homelab-daily homelab-weekly homelab-monthly; do
    if curl -sk "$PVE_API/cluster/backup/$jid" -H "$PVE_AUTH" | jq -e '.data.id' >/dev/null 2>&1; then
      curl -sk -X DELETE "$PVE_API/cluster/backup/$jid" -H "$PVE_AUTH" >/dev/null \
        && echo ">>> Removed vzdump job $jid (see /var/lib/vz/dump for old dumps)"
    fi
  done
fi

# Hermes (vm-113) gets root on the Proxmox host too (best-effort)
HERMES_PUB="$ROOT_DIR/src/modules/hermes.pub"
if [ -f "$HERMES_PUB" ]; then
  "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
    "grep -qxF '$(cat "$HERMES_PUB")' /root/.ssh/authorized_keys || echo '$(cat "$HERMES_PUB")' >> /root/.ssh/authorized_keys" \
    2>/dev/null || echo "WARNING: Could not install the Hermes key on Proxmox."
fi

# Proxmox host power savings (idempotent, best-effort)
"${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > "$f" 2>/dev/null; done
   hdparm -S 241 /dev/sda 2>/dev/null || true   # spin down unused HDD after ~30min
   echo ">>> Proxmox: CPU powersave, HDD spin-down 30min"' \
  2>/dev/null || true

# golden image
if ! "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f /var/lib/vz/template/iso/nixos.img" 2>/dev/null; then
  [ -f "$ROOT_DIR/images/nixos.img" ] || { echo "ERROR: Golden image missing. Run: sudo nix build ./src#cloud-image"; exit 1; }
  echo ">>> Uploading golden image..."
  scp -o StrictHostKeyChecking=accept-new "$ROOT_DIR/images/nixos.img" \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:/var/lib/vz/template/iso/nixos.img"
fi

# Terraform
[ -d "$ROOT_DIR/src/.terraform" ] || terraform -chdir="$ROOT_DIR/src" init
# VM ids were renumbered to follow instances.tf; applying against the old state
# would recreate every VM. The migration renames them in place first.
if terraform -chdir="$ROOT_DIR/src" state list 2>/dev/null | grep -q '^module\.instances\.'; then
  echo "ERROR: Terraform state still has the old VM ids. Run src/scripts/renumber.sh first."
  exit 1
fi
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

# inventory for the Nix side (src/inventory.json): evaluated from the Terraform
# config itself, so it is current even when apply was skipped.
INVENTORY="$ROOT_DIR/src/inventory.json"
INVENTORY_NEW=$(echo 'jsonencode(local.inventory)' \
  | terraform -chdir="$ROOT_DIR/src" console -var-file="$ACTIVE_TFVARS_PATH" \
  | jq -r 'fromjson' | jq -S .) || { echo "ERROR: Could not evaluate the Terraform inventory."; exit 1; }
if [ "$INVENTORY_NEW" != "$(cat "$INVENTORY" 2>/dev/null)" ]; then
  echo "$INVENTORY_NEW" > "$INVENTORY"
  echo ">>> Inventory updated: src/inventory.json"
fi

VM_IPS=$(jq -r 'to_entries[] | "\(.key)=\(.value.ip)"' "$INVENTORY")
DISABLED_VMS=$(jq -r 'to_entries[] | select(.value.enabled == "false") | .key' "$INVENTORY")
[ -n "$DISABLED_VMS" ] && echo ">>> Disabled VMs: $(echo "$DISABLED_VMS" | tr '\n' ' ')"

# on-demand VMs are normally stopped (woken by the socket proxy on request and
# shut down when idle). They must be running to receive a deploy, so start them
# now; the on-demand reaper powers them off again after their cooldown.
ON_DEMAND_VMS=$(jq -r 'to_entries[] | select(.value.enabled == "onDemand") | .key' "$INVENTORY")
if [ -n "$ON_DEMAND_VMS" ] && [ -n "$PROXMOX_API_TOKEN_ID" ]; then
  echo ">>> Waking on-demand VMs for deploy: $(echo "$ON_DEMAND_VMS" | tr '\n' ' ')"
  # start every stopped on-demand VM. sync always deploys ALL enabled VMs: the
  # on-demand idle-stop is only for user request traffic, config must never drift.
  for vmid in $ON_DEMAND_VMS; do
    st=$(curl -sk "$PVE_API/nodes/$PROXMOX_NODE/qemu/$vmid/status/current" -H "$PVE_AUTH" | jq -r '.data.status // "unknown"' 2>/dev/null)
    if [ "$st" != "running" ]; then
      echo ">>>   starting vm-$vmid ($st)"
      curl -sk -X POST "$PVE_API/nodes/$PROXMOX_NODE/qemu/$vmid/status/start" -H "$PVE_AUTH" >/dev/null 2>&1 || true
    fi
  done
  # give cold VMs time to boot, then push the SSH key via the guest agent
  # (best-effort: already-deployed VMs carry the key in their config; the push
  # only matters for a fresh VM). The per-VM wait_for_ssh in the deploy loop
  # does the real readiness gate with retries, so a slow boot still deploys.
  sleep 45
  payload=$(jq -cn --arg k "$PUBKEY" \
    '{"command":["/bin/sh","-c","mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \($k) > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"]}')
  for vmid in $ON_DEMAND_VMS; do
    for _ in $(seq 1 20); do   # retry the agent exec until the agent answers
      code=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$PVE_API/nodes/$PROXMOX_NODE/qemu/$vmid/agent/exec" \
        -H "$PVE_AUTH" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
      [ "$code" = "200" ] && break
      sleep 3
    done
  done
fi

# Nix flakes only see files git knows about: stage new/renamed configs (and
# the inventory) before building. Everything is committed at the end anyway.
git -C "$ROOT_DIR" add -A src

# build all enabled closures in parallel
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

# deploy router first (it's the SSH bastion for all other VMs)
echo ">>> Deploying 300-router to $ROUTER_WAN_IP..."
deploy_nixos "300-router" "$ROUTER_WAN_IP" || { echo "WARNING: Router deploy failed"; DEPLOY_FAILURE=1; }

if [ "$DEPLOY_FAILURE" -eq 0 ]; then
  echo ">>> Waiting for router bastion..."
  wait_for_ssh "$ROUTER_WAN_IP" 30 5 || { echo "ERROR: Router unreachable after deploy."; exit 1; }

  echo ">>> Verifying bastion -> internal subnet..."
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

# wait for builds
echo ">>> Waiting for builds..."
if ! wait "$BUILD_PID"; then
  cat "$BUILD_LOG"; echo "ERROR: Build failed."; exit 1
fi
cat "$BUILD_LOG"
echo ">>> All builds complete."

# deploy all other VMs in parallel (HOMELAB_PARALLEL, default 6)
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
