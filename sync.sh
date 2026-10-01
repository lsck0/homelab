#!/bin/bash
# sync the entire lab: apply terraform, deploy nixos
set -euo pipefail
export SHELL=/bin/bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_PATH="$ROOT_DIR/src/terraform.tfvars"
TFVARS_ENC_PATH="$ROOT_DIR/src/terraform.tfvars.sops.json"
# the age key lives in the dotfiles' git-crypt secrets, which the YubiKey unlocks
DOTFILES="${DOTFILES:-$HOME/projects/arch-dotfiles}"
AGE_KEY="$ROOT_DIR/secrets/age.txt"
[ -e "$AGE_KEY" ] || { mkdir -p "$ROOT_DIR/secrets"; ln -sfn "$DOTFILES/configs/secrets/age.txt" "$AGE_KEY"; }
# locked, the file is ciphertext, and every vm would be handed it as its sops key
if ! grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY"; then
  echo ">>> dotfiles secrets locked: touch the YubiKey"
  "$DOTFILES/scripts/yubikey.sh" unlock || true
  grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY" || { echo "ERROR: $AGE_KEY is not an age key, unlock the dotfiles secrets."; exit 1; }
fi
export SOPS_AGE_KEY_FILE="$AGE_KEY"
# deploys log in with this key; src/keys/ authorizes it everywhere. a fresh dotfiles install has no
# ~/.ssh/id_ed25519, only the key in the dotfiles secrets (ssh-add.service loads it into the agent)
DEPLOY_KEY="$HOME/.ssh/id_ed25519"
DEPLOY_PUB="$DEPLOY_KEY.pub"
if [ ! -f "$DEPLOY_PUB" ]; then
  DEPLOY_KEY="$DOTFILES/configs/secrets/ssh_privatekey.asc"
  DEPLOY_PUB="$DOTFILES/configs/secrets/ssh_publickey.asc"
fi
ACTIVE_TFVARS_PATH=""
# the machine and the house network, written by src/scripts/init.sh
SITE="$ROOT_DIR/src/site.json"
ROUTER_WAN_IP=$(jq -r .lan.router "$SITE")
DEPLOY_FAILURE=0
# instance name -> built toplevel, filled once the batch build is done
declare -A TOPLEVELS=()
CLEANUP_FILES=()
CLEANUP_AGENT=0
# the traefiks run the on-demand reaper; it must not shut a guest down mid-deploy
ONDEMAND_HOSTS=(10.100.0.100 10.200.0.200)
REAPER_PAUSE_FILE=/run/ondemand-reaper-pause-until
# outlives any sync, expires on its own if the trap never runs
REAPER_PAUSE_SECONDS=14400
REAPER_PAUSED=0
cleanup() {
  [ "$REAPER_PAUSED" = 1 ] && reaper_resume
  [ "$CLEANUP_AGENT" = 1 ] && ssh-agent -k >/dev/null 2>&1
  rm -rf "${CLEANUP_FILES[@]}"
}
trap cleanup EXIT

echo ">>> SYNCING HARDWARE + OS..."

# abort if behind upstream
git -C "$ROOT_DIR" fetch origin --quiet 2>/dev/null || true
BEHIND=$(git -C "$ROOT_DIR" rev-list "HEAD..@{u}" --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
  echo "ERROR: Branch is $BEHIND commit(s) behind upstream. Run 'git pull' first."
  exit 1
fi

# -----------------------------------------------------------------------------
# HELPERS
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
  sops --decrypt "$TFVARS_ENC_PATH" > "$ACTIVE_TFVARS_PATH"
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

# a deadline, not a stop: switch-to-configuration restarts timers.target and with it a stopped reaper timer
reaper_pause() {
  local ip
  for ip in "${ONDEMAND_HOSTS[@]}"; do
    ssh -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@$ip" \
      "echo \$((\$(date +%s) + $REAPER_PAUSE_SECONDS)) > $REAPER_PAUSE_FILE" 2>/dev/null \
      || echo "WARNING: could not pause the on-demand reaper on $ip"
  done
  REAPER_PAUSED=1
}

reaper_resume() {
  local ip
  for ip in "${ONDEMAND_HOSTS[@]}"; do
    ssh -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@$ip" "rm -f $REAPER_PAUSE_FILE" 2>/dev/null \
      || echo "WARNING: could not resume the on-demand reaper on $ip, it resumes by itself at the deadline"
  done
}

# returns 1 if it had to start the vm
vm_wake() {
  local st kind
  # containers live under /lxc, vms under /qemu
  kind=$(jq -r --arg id "$1" '.[$id].kind // "vm"' "$ROOT_DIR/src/inventory.json" 2>/dev/null)
  [ "$kind" = lxc ] && kind=lxc || kind=qemu
  st=$(curl -sk "$PVE_API/nodes/$PROXMOX_NODE/$kind/$1/status/current" -H "$PVE_AUTH" | jq -r '.data.status // "unknown"' 2>/dev/null)
  [ "$st" = "running" ] && return 0
  echo ">>>   starting vm-$1 ($st)"
  curl -sk -X POST "$PVE_API/nodes/$PROXMOX_NODE/$kind/$1/status/start" -H "$PVE_AUTH" >/dev/null 2>&1 || true
  return 1
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."
  wait_for_ssh "$ip" 60 5 || return 1

  # the router deploys before the batch build finishes, so it builds its own
  local toplevel="${TOPLEVELS[$name]:-}"
  if [ -z "$toplevel" ]; then
    toplevel=$(nix build "$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel" \
      --extra-experimental-features "nix-command flakes" --no-link --print-out-paths 2>&1 | tail -n1)
  fi
  [ -n "$toplevel" ] && [ -e "$toplevel" ] || { echo "ERROR: Build failed for $name"; return 1; }

  local current
  current=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "readlink -f /run/current-system" 2>/dev/null || true)
  [ "$current" = "$toplevel" ] && { echo ">>> $name already up-to-date. Skipping."; return 0; }

  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "install -d -m 700 /var/lib/sops-nix && cat > /var/lib/sops-nix/key.txt && chmod 600 /var/lib/sops-nix/key.txt" \
    < "$AGE_KEY" || return 1

  # closures are local builds, no sigs
  nix copy --extra-experimental-features "nix-command flakes" --no-check-sigs --to "ssh-ng://root@${ip}" "$toplevel" \
    || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  # switch in place, no reboot
  local out rc=0 failed
  out=$(mktemp)
  ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${toplevel}' \
     && '${toplevel}/bin/switch-to-configuration' switch" 2>&1 | tee "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # podman healthchecks fire mid-restart; those alone are not a failed deploy
    # the timer suffix is hex without leading zeros, 15 digits seen on vm-103
    failed=$(sed -n 's/^warning: the following units failed: //p' "$out" | tr ',' '\n' | tr -d ' ' \
      | grep -v -E '^[0-9a-f]{64}-[0-9a-f]{1,16}\.service$' || true)
    if grep -q '^warning: the following units failed: ' "$out" && [ -z "$failed" ]; then
      echo ">>> $name: only podman healthchecks failed during the switch, ignoring."
    else
      rm -f "$out"; return 1
    fi
  fi
  rm -f "$out"
  echo ">>> $name deployed."

  # a terraform disk bump grows the qcow live but not the guest partition; reboot so
  # boot.growPartition expands it. no-op for lxc (no /dev/sda) and once the partition fills.
  local disk part
  disk=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "lsblk -brno SIZE /dev/sda 2>/dev/null | head -1" 2>/dev/null || true)
  part=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "lsblk -brno SIZE /dev/sda1 2>/dev/null | head -1" 2>/dev/null || true)
  if [ -n "$disk" ] && [ -n "$part" ] && [ $((disk - part)) -gt 67108864 ]; then
    echo ">>> $name: disk grew to $((disk / 1024 / 1024 / 1024))G, rebooting to expand the partition"
    ssh -o StrictHostKeyChecking=accept-new "${BASTION_SSHOPTS[@]}" "root@${ip}" "systemctl reboot" 2>/dev/null || true
    sleep 5
    wait_for_ssh "$ip" 60 5 || echo "WARNING: $name did not return after the grow reboot"
  fi
}

# -----------------------------------------------------------------------------
# MAIN
load_tfvars

# ssh transport
PROXMOX_SSH_HOST=$(jq -r .lan.proxmox "$SITE")
PROXMOX_SSH_PORT="$(read_tfvar proxmox_ssh_port)"; : "${PROXMOX_SSH_PORT:=22}"
PROXMOX_SSH_USER="$(read_tfvar proxmox_ssh_user)"; : "${PROXMOX_SSH_USER:=root}"
PROXMOX_SSH_PASSWORD="$(read_tfvar proxmox_ssh_password)"

# the lab's host keys, also pinned by the owner's ssh config (arch-dotfiles configs/ssh/config)
LAB_KNOWN_HOSTS="$HOME/.ssh/known_hosts.homelab"
# refreshes one host's entry; a guest recreated by terraform comes back with a new key
lab_known_host() {
  local key
  # keyscan prints a banner comment; grep fails when no key came back
  key=$(ssh-keyscan -T 3 -t ed25519 -p "${2:-22}" "$1" 2>/dev/null | grep -v "^#") || return 1
  ssh-keygen -R "$1" -f "$LAB_KNOWN_HOSTS" >/dev/null 2>&1 || true
  echo "$key" >> "$LAB_KNOWN_HOSTS"
  rm -f "$LAB_KNOWN_HOSTS.old"
}

SSH_CMD=(ssh -p "$PROXMOX_SSH_PORT" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS")
if [ -n "$PROXMOX_SSH_PASSWORD" ]; then
  # -e reads SSHPASS: -p would show the password in ps
  export SSHPASS="$PROXMOX_SSH_PASSWORD"
  SSH_CMD=(sshpass -e "${SSH_CMD[@]}")
fi

[ -f "$DEPLOY_PUB" ] && cat "$ROOT_DIR"/src/keys/*.pub | grep -qF "$(cut -d' ' -f2 "$DEPLOY_PUB")" \
  || { echo "ERROR: $DEPLOY_PUB is not in src/keys/. Add it, then deploy once from a machine whose key is."; exit 1; }

# bpg provider imports vm disks over ssh, through the agent
if ! ssh-add -l >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
  CLEANUP_AGENT=1
fi
ssh-add -T "$DEPLOY_PUB" 2>/dev/null || ssh-add "$DEPLOY_KEY" </dev/null >/dev/null 2>&1 \
  || echo "WARNING: could not add the deploy key to the ssh-agent."

mkdir -p "$HOME/.ssh" && touch "$LAB_KNOWN_HOSTS"
lab_known_host "$PROXMOX_SSH_HOST" "$PROXMOX_SSH_PORT" \
  || { echo "ERROR: Cannot reach Proxmox at $PROXMOX_SSH_HOST:$PROXMOX_SSH_PORT"; exit 1; }

SSH_CONFIG="$(mktemp --suffix=.ssh_config)"; CLEANUP_FILES+=("$SSH_CONFIG")

# skip the router bastion when 10.x routes directly
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

PROXMOX_API_TOKEN_ID="$(read_tfvar proxmox_api_token_id)"
PROXMOX_API_TOKEN_SECRET="$(read_tfvar proxmox_api_token_secret)"
PROXMOX_NODE=$(jq -r .node "$SITE")
PVE_API="https://$PROXMOX_SSH_HOST:8006/api2/json"
PVE_AUTH="Authorization: PVEAPIToken=$PROXMOX_API_TOKEN_ID=$PROXMOX_API_TOKEN_SECRET"

# proxmox root takes exactly src/keys plus the node's own key, which pve uses to reach itself
cat "$ROOT_DIR"/src/keys/*.pub | "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'keys=$(cat); [ -n "$keys" ] || exit 1
   f=$(readlink -f /root/.ssh/authorized_keys)
   { grep " root@$(hostname)\$" "$f"; echo "$keys"; } > "$f.new" && cat "$f.new" > "$f" && rm "$f.new"' \
  || echo "WARNING: could not set the Proxmox authorized keys."

# proxmox root password = authelia password
if PVE_ROOT_PASS=$(sops --decrypt \
     --extract '["authelia-admin-pass"]' "$ROOT_DIR/src/secrets.json" 2>/dev/null) \
   && [ -n "$PVE_ROOT_PASS" ]; then
  if printf 'root:%s\n' "$PVE_ROOT_PASS" \
       | "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "chpasswd" 2>/dev/null; then
    echo ">>> Proxmox: root password set to the Authelia password."
  else
    echo "WARNING: could not set the Proxmox root password."
  fi
  unset PVE_ROOT_PASS
fi

# proxmox power and noise, applied now and on every host boot: cpu biased to efficiency, hdds sleep after 10 min idle
"${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'printf "%s\n" \
     "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave" \
     "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power" \
     > /etc/tmpfiles.d/homelab-power.conf
   echo "ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"sd[a-z]\", ATTR{queue/rotational}==\"1\", RUN+=\"/usr/sbin/hdparm -S 120 /dev/%k\"" \
     > /etc/udev/rules.d/69-homelab-hdd-spindown.rules
   systemd-tmpfiles --create /etc/tmpfiles.d/homelab-power.conf
   for d in /sys/block/sd*; do [ "$(cat $d/queue/rotational)" = 1 ] && hdparm -q -S 120 /dev/${d##*/}; done
   echo ">>> Proxmox: cpu powersave/balance_power, hdd spin-down 10min"' \
  || echo "WARNING: could not set the Proxmox power settings."

# containers cannot load kernel modules: nfs for the privileged ones, the rest for docker swarm
"${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'printf "%s\n" nfs nfsv4 overlay br_netfilter ip_vs ip_vs_rr vxlan > /etc/modules-load.d/homelab-lxc.conf
   for m in nfs nfsv4 overlay br_netfilter ip_vs ip_vs_rr vxlan; do modprobe "$m"; done' \
  2>/dev/null || echo "WARNING: could not load the lxc kernel modules on Proxmox."

# bulk (hdd) stays disabled in proxmox: pvestatd polls enabled storages every 10s, which keeps the disk
# spinning; vm-109's hookscript enables it only around its own start and stop
"${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'set -e
   grep -A3 "^dir: local$" /etc/pve/storage.cfg | grep -q snippets || pvesm set local --content backup,vztmpl,iso,snippets
   install -d /var/lib/vz/snippets
   cat > /var/lib/vz/snippets/homelab-bulk.sh <<"HOOK"
#!/bin/sh
case "$2" in
  pre-start|pre-stop) pvesm set bulk --disable 0 ;;
  post-start|post-stop) pvesm set bulk --disable 1 ;;
esac
exit 0
HOOK
   chmod 755 /var/lib/vz/snippets/homelab-bulk.sh
   qm config 109 | grep -q "^hookscript: local:snippets/homelab-bulk.sh" || qm set 109 --hookscript local:snippets/homelab-bulk.sh >/dev/null
   [ "$(qm status 109 | cut -d" " -f2)" = running ] && pvesm set bulk --disable 1
   # onboot start checks the storage before the hookscript runs, so host boot enables bulk for the autostart
   d=/etc/systemd/system/pve-guests.service.d; install -d $d
   printf "[Service]\nExecStartPre=/usr/sbin/pvesm set bulk --disable 0\n" > $d/homelab-bulk.conf.new
   if cmp -s $d/homelab-bulk.conf.new $d/homelab-bulk.conf; then rm -f $d/homelab-bulk.conf.new
   else mv $d/homelab-bulk.conf.new $d/homelab-bulk.conf; systemctl daemon-reload; fi
   # disabled or not, pvestatd'"'"'s lvm scans for local-lvm read every pv label, the hdd too:
   # give it its own lvm config that rejects every name of the bulk pv, rebuilt from the real one each run
   pv=$(pvs --noheadings -o pv_name,vg_name | awk '"'"'$2=="bulk"{print $1}'"'"')
   rej=$(for n in "$pv" /dev/disk/by-id/*; do [ "$(readlink -f "$n")" = "$(readlink -f "$pv")" ] && printf ",\"r|^%s$|\"" "$n"; done)
   rm -rf /etc/lvm-pvestatd.new && cp -a /etc/lvm /etc/lvm-pvestatd.new
   sed -i "s#^\(\s*global_filter=\[.*\)\]#\1$rej]#" /etc/lvm-pvestatd.new/lvm.conf
   LVM_SYSTEM_DIR=/etc/lvm-pvestatd.new vgs pve >/dev/null
   rm -rf /etc/lvm-pvestatd && mv /etc/lvm-pvestatd.new /etc/lvm-pvestatd
   d=/etc/systemd/system/pvestatd.service.d; install -d $d
   printf "[Service]\nEnvironment=LVM_SYSTEM_DIR=/etc/lvm-pvestatd\n" > $d/homelab-no-hdd.conf.new
   if cmp -s $d/homelab-no-hdd.conf.new $d/homelab-no-hdd.conf; then rm -f $d/homelab-no-hdd.conf.new
   else mv $d/homelab-no-hdd.conf.new $d/homelab-no-hdd.conf; systemctl daemon-reload; systemctl restart pvestatd; fi
   echo ">>> Proxmox: bulk storage idle-disabled, vm-109 hookscript in place"' \
  || echo "WARNING: could not set up the bulk storage hookscript."

# golden image
if ! "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f /var/lib/vz/template/iso/nixos.img" 2>/dev/null; then
  [ -f "$ROOT_DIR/images/nixos.img" ] || { echo "ERROR: Golden image missing. Run: sudo nix build ./src#cloud-image"; exit 1; }
  echo ">>> Uploading golden image..."
  scp -P "$PROXMOX_SSH_PORT" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" "$ROOT_DIR/images/nixos.img" \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:/var/lib/vz/template/iso/nixos.img"
fi

# lxc template; only seeds new containers, so upload once
LXC_TEMPLATE=/var/lib/vz/template/cache/nixos-homelab.tar.xz
if ! "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f $LXC_TEMPLATE" 2>/dev/null; then
  echo ">>> Building and uploading the LXC template..."
  tarball=$(nix build "$ROOT_DIR/src#lxc-template" --extra-experimental-features "nix-command flakes" \
    --no-link --print-out-paths)
  scp -P "$PROXMOX_SSH_PORT" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" "$tarball"/tarball/*.tar.xz \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:$LXC_TEMPLATE"
fi

# terraform
[ -d "$ROOT_DIR/src/.terraform" ] || terraform -chdir="$ROOT_DIR/src" init
# every run, with refresh: proxmox drift (a half-failed apply, a manual edit) is corrected, never trusted
echo ">>> Terraform: applying..."
for i in $(seq 1 5); do
  terraform -chdir="$ROOT_DIR/src" apply -auto-approve -parallelism=3 -var-file="$ACTIVE_TFVARS_PATH" && break
  [ "$i" -eq 5 ] && { echo "ERROR: Terraform failed after 5 attempts."; exit 1; }
  echo "Retrying ($i/5)..."; sleep 5
done

# nix inventory, evaluated from terraform
INVENTORY="$ROOT_DIR/src/inventory.json"
INVENTORY_NEW=$(echo 'jsonencode(local.inventory)' \
  | terraform -chdir="$ROOT_DIR/src" console -var-file="$ACTIVE_TFVARS_PATH" \
  | jq -r 'fromjson' | jq -S .) || { echo "ERROR: Could not evaluate the Terraform inventory."; exit 1; }
if [ "$INVENTORY_NEW" != "$(cat "$INVENTORY" 2>/dev/null)" ]; then
  echo "$INVENTORY_NEW" > "$INVENTORY"
  echo ">>> Inventory updated: src/inventory.json"
fi

# lxc features: root@pam only, so not terraform; a change needs a restart
sorted_features() { tr , '\n' | sort | paste -sd, -; }
for vmid in $(jq -r 'to_entries[] | select(.value.kind == "lxc" and .value.enabled != "false") | .key' "$INVENTORY"); do
  want=$(jq -r --arg id "$vmid" '.[$id].features' "$INVENTORY" | sorted_features)
  have=$("${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "pct config $vmid 2>/dev/null | sed -n 's/^features: //p'" | sorted_features || true)
  [ "$want" = "$have" ] && continue
  echo ">>> lxc-$vmid features: ${have:-none} -> $want"
  "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
    "pct set $vmid --features $want && if pct status $vmid | grep -q running; then pct reboot $vmid; fi" \
    || echo "WARNING: could not set features on lxc-$vmid"
done

# bpg 0.70 never reads a container's onboot back, so drift there is invisible to terraform: on-demand
# containers must stay off at host boot
for vmid in $(jq -r 'to_entries[] | select(.value.kind == "lxc") | .key' "$INVENTORY"); do
  want=$(jq -r --arg id "$vmid" 'if .[$id].enabled == "true" then 1 else 0 end' "$INVENTORY")
  "${SSH_CMD[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
    "o=\$(pct config $vmid | sed -n 's/^onboot: //p'); [ \"\${o:-0}\" = $want ] || { pct set $vmid --onboot $want && echo '>>> lxc-$vmid onboot -> $want'; }" \
    || echo "WARNING: could not set onboot on lxc-$vmid"
done

VM_IPS=$(jq -r 'to_entries[] | "\(.key)=\(.value.ip)"' "$INVENTORY")
DISABLED_VMS=$(jq -r 'to_entries[] | select(.value.enabled == "false") | .key' "$INVENTORY")
[ -n "$DISABLED_VMS" ] && echo ">>> Disabled VMs: $(echo "$DISABLED_VMS" | tr '\n' ' ')" || true

reaper_pause

# enabled vms must run to receive a deploy
WAKE_VMS=$(jq -r 'to_entries[] | select(.value.enabled != "false") | .key' "$INVENTORY")
if [ -n "$WAKE_VMS" ] && [ -n "$PROXMOX_API_TOKEN_ID" ]; then
  WOKE=0
  for vmid in $WAKE_VMS; do vm_wake "$vmid" || WOKE=1; done
  # boot wait only if one started
  [ "$WOKE" = 1 ] && sleep 45 || true
fi

# flakes only see git-tracked files
git -C "$ROOT_DIR" add -A src

# one nix process for every closure: one per vm ran the workstation out of memory
echo ">>> Building all VM closures..."
BUILD_LOG=$(mktemp --suffix=.build.log); CLEANUP_FILES+=("$BUILD_LOG")
# out links are gc roots until the deploys are done
BUILD_DIR=$(mktemp -d --suffix=.build); CLEANUP_FILES+=("$BUILD_DIR")
BUILD_NAMES=(); BUILD_TARGETS=()
for f in "$ROOT_DIR"/src/instances/{1,2}[0-9][0-9]-*.nix; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .nix); vm_id="${name%%-*}"
  if echo "$DISABLED_VMS" | grep -qx "$vm_id"; then
    echo ">>> Skipping build for $name (disabled)"; continue
  fi
  BUILD_NAMES+=("$name")
  BUILD_TARGETS+=("$ROOT_DIR/src#nixosConfigurations.${name}.config.system.build.toplevel")
done
BUILD_PID=""
if [ "${#BUILD_TARGETS[@]}" -gt 0 ]; then
  nix build "${BUILD_TARGETS[@]}" --extra-experimental-features "nix-command flakes" \
    --keep-going --out-link "$BUILD_DIR/result" > "$BUILD_LOG" 2>&1 &
  BUILD_PID=$!
fi

# router first, it is the ssh bastion
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
if [ -n "$BUILD_PID" ] && ! wait "$BUILD_PID"; then
  cat "$BUILD_LOG"; echo "ERROR: Build failed."; exit 1
fi
cat "$BUILD_LOG"
# nix names the out link of installable i result-i, the first plain result
for i in "${!BUILD_NAMES[@]}"; do
  link="$BUILD_DIR/result"; [ "$i" -gt 0 ] && link="$link-$i"
  TOPLEVELS[${BUILD_NAMES[$i]}]=$(readlink -f "$link")
done
echo ">>> All builds complete."

# deploy the rest in parallel
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

  # the reaper may have stopped it meanwhile
  if [ -n "$PROXMOX_API_TOKEN_ID" ] && echo "$WAKE_VMS" | grep -qx "$vm_id"; then
    vm_wake "$vm_id" || true
  fi
  deploy_nixos "$name" "$ip" &
  DEPLOY_PIDS+=("$!"); DEPLOY_NAMES+=("$name")
done

for i in "${!DEPLOY_PIDS[@]}"; do
  wait "${DEPLOY_PIDS[$i]}" || { echo "WARNING: Failed to deploy ${DEPLOY_NAMES[$i]}"; DEPLOY_FAILURE=1; }
done

for ip in $(jq -r '.[].ip' "$INVENTORY"); do lab_known_host "$ip" || true; done

# commit + push, even on partial failure: src as staged for the build, plus the generated inventory
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" add -- src/inventory.json
  if ! git -C "$ROOT_DIR" diff --cached --quiet; then
    # every commit is Generation: <n>, numbered by position
    next=$(( $(git -C "$ROOT_DIR" rev-list --count HEAD) + 1 ))
    echo ">>> Git: committing generation $next"
    git -C "$ROOT_DIR" commit -m "Generation: $next"
    git -C "$ROOT_DIR" push || echo "WARNING: git push failed."
  fi
fi

[ "$DEPLOY_FAILURE" -ne 0 ] && { echo "ERROR: One or more deployments failed."; exit 1; }
echo ">>> LAB IS FULLY SYNCHRONIZED"
