#!/usr/bin/env bash
# sync the entire lab: apply terraform, deploy nixos, commit the generation
#
# Trust: the Proxmox host's ssh key is pinned in src/generated/known_hosts by src/scripts/init.sh --pin, after the owner
# compared its fingerprint on the console. Every guest's host key is read through that pinned channel from the
# hypervisor's own view of the guest (qemu guest agent, pct pull) and written to src/generated/known_hosts, and every ssh of the
# run checks it strictly. Nothing secret goes to an address whose key the network vouched for.
#
# Each guest gets only its own age key (src/scripts/secrets-sync.sh); the admin key never leaves this machine.
#
# env: TF_STATE_FRESH=1    first deploy of an empty lab: no terraform state on the nas yet
#      TF_STATE_OFFLINE=1  the nas is down: apply from the local state copy without its lock (it may be behind)
#      HOMELAB_PARALLEL    deploys at once (default DEPLOY_PARALLEL_DEFAULT)
# shellcheck disable=SC2016 # the remote scripts are single-quoted on purpose: they expand on the Proxmox host
set -euo pipefail
export SHELL=/bin/bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT_DIR/src"
# shellcheck source=src/scripts/lib/tools.sh
. "$SRC/scripts/lib/tools.sh"
# shellcheck source=src/scripts/lib/tfstate.sh
. "$SRC/scripts/lib/tfstate.sh"
# shellcheck source=src/scripts/lib/secrets.sh
. "$SRC/scripts/lib/secrets.sh"
# shellcheck source=src/scripts/lib/proxmox.sh
. "$SRC/scripts/lib/proxmox.sh"
tools_require git jq sops ssh ssh-keygen ssh-agent ssh-add terraform nix curl openssl

# the age key lives in the dotfiles' git-crypt secrets, which the YubiKey unlocks; the link follows them when they move
AGE_KEY="$ROOT_DIR/secrets/age.txt"
secrets_age_key_link "$AGE_KEY"
# locked, the file is ciphertext and no secret decrypts
if ! grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY"; then
  echo ">>> dotfiles secrets locked: touch the YubiKey"
  # a failed unlock is reported by the check below
  "$SECRETS_DOTFILES/scripts/yubikey.sh" unlock || true
  grep -qs '^AGE-SECRET-KEY-' "$AGE_KEY" || { echo "ERROR: $AGE_KEY is not an age key, unlock the dotfiles secrets."; exit 1; }
fi
export SOPS_AGE_KEY_FILE="$AGE_KEY"
# deploys log in with this key; src/lab/keys/ authorizes it everywhere
DEPLOY_KEY="$HOME/.ssh/id_ed25519"
DEPLOY_PUB="$DEPLOY_KEY.pub"
# a fresh dotfiles install has the key only in the dotfiles secrets
if [ ! -f "$DEPLOY_PUB" ]; then
  DEPLOY_KEY="$SECRETS_DOTFILES_DIR/ssh_privatekey.asc"
  DEPLOY_PUB="$SECRETS_DOTFILES_DIR/ssh_publickey.asc"
fi
# the machine and the house network, written by src/scripts/init.sh
SITE="$SRC/generated/site.json"
# the guests, collected by nix from src/instances/ and src/apps/swarm.nix (modules/lab); filled below
INVENTORY=""
# the desktop clients' interface (modules/lab-export.nix), written below and committed with the generation
LAB_EXPORT="$SRC/generated/lab.json"
ROUTER_WAN_IP=$(jq -r .lan.router "$SITE")
DEPLOY_FAILURE=0
# instance name -> built toplevel, filled once the batch build is done
declare -A TOPLEVELS=()
CLEANUP_FILES=()
CLEANUP_AGENT=0

# the owner's ssh config (arch-dotfiles configs/ssh/config) reads the lab's keys from here
USER_KNOWN_HOSTS="$HOME/.ssh/known_hosts.homelab"
HOST_KEY_PATH=/etc/ssh/ssh_host_ed25519_key.pub
# a guest booting or rebooting: up to 5 minutes for its sshd, and 3 for its qemu agent or container to answer
SSH_WAIT_ATTEMPTS=60
SSH_WAIT_INTERVAL_S=5
HOST_KEY_ATTEMPTS=36
HOST_KEY_RETRY_S=5
# one ssh call that must not hang the run; a probe in a retry loop gives up sooner
SSH_CONNECT_TIMEOUT_S=5
SSH_PROBE_TIMEOUT_S=3
# after the router's own deploy: 2.5 minutes for the bastion, then 1 for the internal zone behind it
ROUTER_WAIT_ATTEMPTS=30
INGRESS_WAIT_ATTEMPTS=12
# the router's resolver after its deploy: 2 minutes, probed with a name every build pulls from
DNS_WAIT_ATTEMPTS=24
DNS_WAIT_INTERVAL_S=5
DNS_PROBE_NAME=ghcr.io
# a zone gateway answers ssh within this when the house lan routes the zone here
ROUTE_PROBE_TIMEOUT_S=4
PVE_API_PORT=8006
# hdparm -S units of 5 s: 10 minutes
HDD_SPINDOWN_SETTING=120
# containers cannot load kernel modules: nfs for the privileged ones, the rest for docker swarm
LXC_MODULES="nfs nfsv4 overlay br_netfilter ip_vs ip_vs_rr vxlan"
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

# the traefiks run the on-demand reaper; it must not shut a guest down mid-deploy
ONDEMAND_IDS=(100 200)
REAPER_PAUSE_FILE=/run/ondemand-reaper-pause-until
# outlives any sync, expires on its own if the trap never runs
REAPER_PAUSE_SECONDS=14400
REAPER_PAUSED=0
# the internal ingress: the first guest reached through the router bastion
INGRESS_ID=100
# {"<instance>": "<its age key>"}, from secrets-sync.sh: each host gets its own key, never the admin key
HOST_KEYS_FILE=""
HOST_AGE_KEY_PATH=/var/lib/sops-nix/key.txt
# terraform's state lives on the nas, which kopia snapshots; src/generated/terraform/terraform.tfstate is only the
# working copy, the path terraform/main.tf's backend names
NAS_ID=109
TFSTATE_LOCAL="$SRC/generated/terraform/terraform.tfstate"
TF_DIR="$SRC/terraform"
STATE_REMOTE=/srv/nas/terraform/terraform.tfstate
STATE_LOCK_REMOTE=/srv/nas/terraform/.lock
TF_ATTEMPTS=5
TF_RETRY_S=5
TF_PARALLELISM=3
# a terraform disk bump grows the disk but not the partition: more unpartitioned space than this reboots the guest
# so boot.growPartition takes it; 64 MiB is above the alignment slack every partitioning leaves
GROW_REBOOT_SLACK_BYTES=$((64 * 1024 * 1024))
DEPLOY_PARALLEL_DEFAULT=6

cleanup() {
  [ "$REAPER_PAUSED" = 1 ] && reaper_resume
  tfstate_lock_release
  [ "$CLEANUP_AGENT" = 1 ] && ssh-agent -k >/dev/null 2>&1
  rm -rf "${CLEANUP_FILES[@]}"
}
trap cleanup EXIT

# the same facts every host and terraform read: no generated file to go stale
INVENTORY=$(mktemp --suffix=.inventory.json); CLEANUP_FILES+=("$INVENTORY")
nix eval "${NIX_FEATURES[@]}" --json --no-warn-dirty "$SRC#lab.inventory" > "$INVENTORY" \
  || { echo "ERROR: the lab's instances do not evaluate (nix eval .#lab.inventory)."; exit 1; }
# beside it, so the rename below is atomic: a reader never sees half a file, a failed eval keeps the old one
LAB_EXPORT_NEW=$(mktemp "$LAB_EXPORT.XXXXXX"); CLEANUP_FILES+=("$LAB_EXPORT_NEW")
nix eval "${NIX_FEATURES[@]}" --json --no-warn-dirty "$SRC#lab.export" | jq . > "$LAB_EXPORT_NEW" \
  || { echo "ERROR: the desktop clients' export does not evaluate (nix eval .#lab.export)."; exit 1; }
chmod 644 "$LAB_EXPORT_NEW"
mv "$LAB_EXPORT_NEW" "$LAB_EXPORT"

echo ">>> SYNCING HARDWARE + OS..."

# abort if behind upstream; offline, or without an upstream, there is nothing to be behind
git -C "$ROOT_DIR" fetch origin --quiet 2>/dev/null || true
BEHIND=$(git -C "$ROOT_DIR" rev-list "HEAD..@{u}" --count 2>/dev/null || echo "0")
if [ "$BEHIND" -gt 0 ]; then
  echo "ERROR: Branch is $BEHIND commit(s) behind upstream. Run 'git pull' first."
  exit 1
fi

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
ip_of() { jq -r --arg id "$1" '.[$id].ip // empty' "$INVENTORY"; }
name_of() { jq -r --arg id "$1" '.[$id].name' "$INVENTORY"; }
# the proxmox api's guest type: containers live under /lxc, vms under /qemu
kind_of() { jq -r --arg id "$1" 'if .[$id].kind == "lxc" then "lxc" else "qemu" end' "$INVENTORY"; }

# ssh to a lab host: the generated config pins every host key and routes each zone
# shellcheck disable=SC2029 # remote commands are assembled here from this run's own values
lab_ssh() { ssh "${BASTION_SSHOPTS[@]}" "$@"; }

wait_for_ssh() {
  local ip="$1" attempts="${2:-$SSH_WAIT_ATTEMPTS}" interval="${3:-$SSH_WAIT_INTERVAL_S}"
  for _ in $(seq 1 "$attempts"); do
    lab_ssh -o ConnectTimeout="$SSH_PROBE_TIMEOUT_S" "root@${ip}" true 2>/dev/null && return 0
    sleep "$interval"
  done
  echo "ERROR: SSH not reachable at $ip"; return 1
}

# a deadline, not a stop: switch-to-configuration restarts timers.target and with it a stopped reaper timer
reaper_pause() {
  local id
  for id in "${ONDEMAND_IDS[@]}"; do
    lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$(ip_of "$id")" \
      "echo \$((\$(date +%s) + $REAPER_PAUSE_SECONDS)) > $REAPER_PAUSE_FILE" 2>/dev/null \
      || echo "WARNING: could not pause the on-demand reaper on vm-$id"
  done
  REAPER_PAUSED=1
}

reaper_resume() {
  local id
  for id in "${ONDEMAND_IDS[@]}"; do
    lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$(ip_of "$id")" "rm -f $REAPER_PAUSE_FILE" 2>/dev/null \
      || echo "WARNING: could not resume the on-demand reaper on vm-$id, it resumes by itself at the deadline"
  done
}

# the nas side of lib/tfstate.sh
tfstate_remote_read() {
  local out
  out=$(lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$(ip_of "$NAS_ID")" \
    "if [ -f $STATE_REMOTE ]; then cat $STATE_REMOTE; else echo NO_STATE; fi") || return 1
  [ "$out" = NO_STATE ] && return 2
  printf '%s\n' "$out" > "$1"
}
# the previous state stays next to it; kopia keeps the history
tfstate_remote_write() {
  lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$(ip_of "$NAS_ID")" \
    "umask 077 && mkdir -p ${STATE_REMOTE%/*} && cat > $STATE_REMOTE.new && sync $STATE_REMOTE.new \
     && { [ ! -f $STATE_REMOTE ] || cp -p $STATE_REMOTE $STATE_REMOTE.prev; } && mv $STATE_REMOTE.new $STATE_REMOTE" < "$1"
}
# the lock lives as long as this ssh: closing its stdin, or losing the connection, drops it
tfstate_remote_lock() {
  lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" -o ServerAliveInterval=15 "root@$(ip_of "$NAS_ID")" \
    "mkdir -p ${STATE_REMOTE%/*} && { flock -n $STATE_LOCK_REMOTE -c 'echo locked; exec cat >/dev/null' || echo busy; }"
}

pve_api() { curl -sf -k --pinnedpubkey "$PVE_TLS_PIN" -H @"$PVE_AUTH_FILE" "$@"; }

# vm_wake <id>: start the guest unless it runs; a start that fails surfaces as its deploy's ssh wait timing out
vm_wake() {
  local st kind
  kind=$(kind_of "$1")
  st=$(pve_api "$PVE_API/nodes/$PROXMOX_NODE/$kind/$1/status/current" | jq -r '.data.status // "unknown"' 2>/dev/null || echo unknown)
  [ "$st" != "running" ] || return 0
  echo ">>>   starting vm-$1 ($st)"
  pve_api -X POST "$PVE_API/nodes/$PROXMOX_NODE/$kind/$1/status/start" >/dev/null 2>&1 || true
}

# guest_host_keys_read <id>...: "<id> <key type> <key>" for every guest whose ed25519 host key the hypervisor could
# read from inside it; a guest still booting is left out
guest_host_keys_read() {
  local args=() id kind payload type key _
  for id in "$@"; do args+=("$id:$(kind_of "$id")"); done
  # on proxmox: "<id> lxc <key line>" (pct pull) or "<id> vm <agent json>"; the final true ignores a silent last guest
  local remote
  remote=$(cat <<'REMOTE'
for g in "${@:2}"; do
  id=${g%:*}
  if [ "${g#*:}" = lxc ]; then
    # pull, not exec: a nixos container has no cat on pct's PATH
    t=$(mktemp) && pct pull "$id" "$1" "$t" 2>/dev/null && printf '%s lxc %s\n' "$id" "$(cat "$t")"
    rm -f "$t"
  else
    out=$(qm guest exec "$id" --timeout 10 -- cat "$1" 2>/dev/null) && printf '%s vm %s\n' "$id" "$(echo "$out" | tr -d '\n')"
  fi
done
true
REMOTE
)
  "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "bash -s -- $HOST_KEY_PATH ${args[*]}" <<<"$remote" \
    | while read -r id kind payload; do
        # a reply that is no json, or no key line, is filtered out below
        [ "$kind" = vm ] && payload=$(jq -r '."out-data" // empty' <<<"$payload" 2>/dev/null || true)
        read -r type key _ <<<"$payload" || true
        if [ "$type" = ssh-ed25519 ] && [[ "$key" =~ ^[A-Za-z0-9+/]+=*$ ]]; then echo "$id $type $key"; fi
      done
}

# host_keys_learn <id>...: rewrites the guests' lines of src/generated/known_hosts from the hypervisor's view; a guest it cannot
# read keeps its previous line, and fails its deploy if it has none
host_keys_learn() {
  local pending=("$@") attempt id type key ip old new
  declare -A learned=()
  for attempt in $(seq 1 "$HOST_KEY_ATTEMPTS"); do
    while read -r id type key; do learned[$id]="$type $key"; done < <(guest_host_keys_read "${pending[@]}")
    pending=(); for id in "$@"; do [ -n "${learned[$id]:-}" ] || pending+=("$id"); done
    [ "${#pending[@]}" = 0 ] && break
    [ "$attempt" = "$HOST_KEY_ATTEMPTS" ] || sleep "$HOST_KEY_RETRY_S"
  done
  [ "${#pending[@]}" = 0 ] \
    || echo "WARNING: no host key from the hypervisor for $(printf 'vm-%s ' "${pending[@]}")(agent or container not answering)"
  new=$(umask 022; mktemp "$(dirname "$LAB_KNOWN_HOSTS")/.known_hosts.XXXXXX")
  {
    echo "# every ssh host key of the lab, checked strictly by sync.sh, hermes and the owner's ssh config"
    echo "# Proxmox: pinned by src/scripts/init.sh --pin after a console check. Guests: written by sync.sh from each"
    echo "# guest's own $HOST_KEY_PATH, read through the Proxmox host (qemu agent, pct pull)"
    awk -v ip="$PROXMOX_SSH_HOST" '$1 == ip || $1 == "[" ip "]:" port' port="$PROXMOX_SSH_PORT" "$LAB_KNOWN_HOSTS"
    for id in $(jq -r 'keys[]' "$INVENTORY"); do
      ip=$(ip_of "$id")
      old=$(awk -v ip="$ip" '$1 == ip { print $2 " " $3; exit }' "$LAB_KNOWN_HOSTS")
      if [ -n "${learned[$id]:-}" ]; then
        [ -n "$old" ] && [ "$old" != "${learned[$id]}" ] && echo ">>> vm-$id: new host key (the guest was recreated)" >&2
        echo "$ip ${learned[$id]}"
      elif [ -n "$old" ]; then
        echo "$ip $old"
      fi
    done
  } > "$new"
  mv "$new" "$LAB_KNOWN_HOSTS"
}

# host_age_key_push <name> <ip>: this host's own age key, written only when it differs; prints "changed" if it did
host_age_key_push() {
  local host_key
  host_key=$(jq -r --arg n "$1" '.[$n] // empty' "$HOST_KEYS_FILE")
  [ -n "$host_key" ] || { echo "ERROR: no age key for $1: src/scripts/secrets-sync.sh did not plan it" >&2; return 1; }
  printf '%s\n' "$host_key" | lab_ssh "root@$2" \
    "install -d -m 700 ${HOST_AGE_KEY_PATH%/*} && umask 077 && cat > $HOST_AGE_KEY_PATH.new \
     && if cmp -s $HOST_AGE_KEY_PATH.new $HOST_AGE_KEY_PATH; then rm $HOST_AGE_KEY_PATH.new; \
        else mv $HOST_AGE_KEY_PATH.new $HOST_AGE_KEY_PATH && echo changed; fi"
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."
  ssh-keygen -F "$ip" -f "$LAB_KNOWN_HOSTS" >/dev/null \
    || { echo "ERROR: no host key for $name ($ip) in src/generated/known_hosts: the hypervisor could not read it"; return 1; }
  wait_for_ssh "$ip" || return 1

  # the router deploys before the batch build finishes, so it builds its own
  local toplevel="${TOPLEVELS[$name]:-}"
  if [ -z "$toplevel" ]; then
    toplevel=$(nix build "$SRC#nixosConfigurations.${name}.config.system.build.toplevel" \
      "${NIX_FEATURES[@]}" --no-link --print-out-paths 2>&1 | tail -n1)
  fi
  [ -n "$toplevel" ] && [ -e "$toplevel" ] || { echo "ERROR: Build failed for $name"; return 1; }

  # before the up-to-date check: a lost or stale key on an unchanged host is repaired, then re-activated
  local key_state current
  key_state=$(host_age_key_push "$name" "$ip") || return 1
  # unreadable means deploy anyway
  current=$(lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@${ip}" "readlink -f /run/current-system" 2>/dev/null || true)
  if [ "$current" = "$toplevel" ] && [ "$key_state" != changed ]; then
    echo ">>> $name already up-to-date. Skipping."; return 0
  fi
  [ "$key_state" = changed ] && echo ">>> $name: age key replaced, re-activating to decrypt its secrets"

  # closures are local builds, no sigs
  nix copy "${NIX_FEATURES[@]}" --no-check-sigs --to "ssh-ng://root@${ip}" "$toplevel" \
    || nix-copy-closure --to "root@${ip}" "$toplevel" || return 1

  # switch in place, no reboot
  local out rc=0 failed
  out=$(mktemp)
  lab_ssh "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${toplevel}' \
     && '${toplevel}/bin/switch-to-configuration' switch" 2>&1 | tee "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # podman healthchecks fire mid-restart and are no failed deploy; their unit is <container id>-<hex timer id>
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

  # a terraform disk bump grows the disk, not the partition (GROW_REBOOT_SLACK_BYTES); an lxc has no /dev/sda, reads 0
  local disk part boot_id
  read -r disk part boot_id < <(lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@${ip}" \
    "echo \$(lsblk -bdno SIZE /dev/sda 2>/dev/null || echo 0) \$(lsblk -bdno SIZE /dev/sda1 2>/dev/null || echo 0) \
     \$(cat /proc/sys/kernel/random/boot_id)" 2>/dev/null || echo "0 0 -")
  if [ "$disk" -gt 0 ] && [ "$part" -gt 0 ] && [ $((disk - part)) -gt "$GROW_REBOOT_SLACK_BYTES" ]; then
    echo ">>> $name: disk grew to $((disk / 1024 / 1024 / 1024))G, rebooting to expand the partition"
    # the reboot drops the connection, which ssh reports as a failure
    lab_ssh "root@${ip}" "systemctl reboot" 2>/dev/null || true
    wait_for_reboot "$ip" "$boot_id" || echo "WARNING: $name did not return after the grow reboot"
  fi
}

# wait_for_reboot <ip> <boot id before>: the guest answers again, with another boot id
wait_for_reboot() {
  local now
  for _ in $(seq 1 "$SSH_WAIT_ATTEMPTS"); do
    # down while it reboots
    now=$(lab_ssh -o ConnectTimeout="$SSH_PROBE_TIMEOUT_S" "root@$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
    [ -n "$now" ] && [ "$now" != "$2" ] && return 0
    sleep "$SSH_WAIT_INTERVAL_S"
  done
  return 1
}

# -----------------------------------------------------------------------------
# PROXMOX
# -----------------------------------------------------------------------------
tfvars_temp=$(umask 077; mktemp --suffix=.tfvars.json)
CLEANUP_FILES+=("$tfvars_temp")
proxmox_tfvars_load "$tfvars_temp" || { echo "ERROR: Missing tfvars. Run ./src/scripts/init.sh first."; exit 1; }
proxmox_login_load

PROXMOX_SSH_HOST=$(jq -r .lan.proxmox "$SITE")
proxmox_ssh_init "$PROXMOX_SSH_HOST" "$PROXMOX_SSH_PORT"
# the owner's own ssh sees what this run trusts
mkdir -p "$HOME/.ssh" && ln -sfn "$LAB_KNOWN_HOSTS" "$USER_KNOWN_HOSTS"

{ [ -f "$DEPLOY_PUB" ] && cat "$SRC"/lab/keys/*.pub | grep -qF "$(cut -d' ' -f2 "$DEPLOY_PUB")"; } \
  || { echo "ERROR: $DEPLOY_PUB is not in src/lab/keys/. Add it, then deploy once from a machine whose key is."; exit 1; }

# bpg provider imports vm disks over ssh, through the agent
if ! ssh-add -l >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
  CLEANUP_AGENT=1
fi
ssh-add -T "$DEPLOY_PUB" 2>/dev/null || ssh-add "$DEPLOY_KEY" </dev/null >/dev/null 2>&1 \
  || echo "WARNING: could not add the deploy key to the ssh-agent."

"${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" true \
  || { echo "ERROR: Cannot reach Proxmox at $PROXMOX_SSH_HOST:$PROXMOX_SSH_PORT, or its host key changed (see above)."; exit 1; }

# the api's tls key, read over the pinned ssh: the certificate is self-signed, the pin is what curl checks
PVE_TLS_PIN="sha256//$("${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'f=/etc/pve/local/pveproxy-ssl.pem; [ -f "$f" ] || f=/etc/pve/local/pve-ssl.pem; openssl x509 -in "$f" -pubkey -noout' \
  | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64)"
PROXMOX_API_TOKEN_ID="$(proxmox_tfvar_read proxmox_api_token_id)"
PROXMOX_API_TOKEN_SECRET="$(proxmox_tfvar_read proxmox_api_token_secret)"
PROXMOX_NODE=$(jq -r .node "$SITE")
PVE_API="https://$PROXMOX_SSH_HOST:$PVE_API_PORT/api2/json"
# a header file, out of argv
PVE_AUTH_FILE=$(umask 077; mktemp); CLEANUP_FILES+=("$PVE_AUTH_FILE")
printf 'Authorization: PVEAPIToken=%s=%s\n' "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET" > "$PVE_AUTH_FILE"
unset PROXMOX_API_TOKEN_SECRET
[ -z "$PROXMOX_API_TOKEN_ID" ] || pve_api "$PVE_API/version" >/dev/null \
  || { echo "ERROR: the Proxmox api refused the token, or its tls key is not the one ssh reads from the host."; exit 1; }

# proxmox root takes exactly src/lab/keys plus the node's own key, which pve uses to reach itself
cat "$SRC"/lab/keys/*.pub | "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  'keys=$(cat); [ -n "$keys" ] || exit 1
   f=$(readlink -f /root/.ssh/authorized_keys)
   { grep " root@$(hostname)\$" "$f"; echo "$keys"; } > "$f.new" && cat "$f.new" > "$f" && rm "$f.new"' \
  || echo "WARNING: could not set the Proxmox authorized keys."

# proxmox root@pam has its own password: one shared with a guest would make root there root on the hypervisor
if PVE_ROOT_PASS=$(sops --decrypt --extract '["proxmox-root-pass"]' "$SRC/$SECRETS_CATALOG_FILE" 2>/dev/null) \
   && [ -n "$PVE_ROOT_PASS" ]; then
  if printf 'root:%s\n' "$PVE_ROOT_PASS" \
       | "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "chpasswd" 2>/dev/null; then
    echo ">>> Proxmox: root password set from proxmox-root-pass."
  else
    echo "WARNING: could not set the Proxmox root password."
  fi
  unset PVE_ROOT_PASS
else
  echo "WARNING: no proxmox-root-pass in src/$SECRETS_CATALOG_FILE: run src/scripts/secrets-sync.sh --apply."
fi

# proxmox power and noise, applied now and on every host boot: cpu biased to efficiency, hdds sleep when idle
"${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  "spindown=$HDD_SPINDOWN_SETTING; "'printf "%s\n" \
     "w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - powersave" \
     "w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - balance_power" \
     > /etc/tmpfiles.d/homelab-power.conf
   echo "ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"sd[a-z]\", ATTR{queue/rotational}==\"1\", RUN+=\"/usr/sbin/hdparm -S $spindown /dev/%k\"" \
     > /etc/udev/rules.d/69-homelab-hdd-spindown.rules
   systemd-tmpfiles --create /etc/tmpfiles.d/homelab-power.conf
   for d in /sys/block/sd*; do [ "$(cat $d/queue/rotational)" = 1 ] && hdparm -q -S "$spindown" /dev/${d##*/}; done
   echo ">>> Proxmox: cpu powersave/balance_power, hdd spin-down 10min"' \
  || echo "WARNING: could not set the Proxmox power settings."

"${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  "modules='$LXC_MODULES'; "'printf "%s\n" $modules > /etc/modules-load.d/homelab-lxc.conf
   for m in $modules; do modprobe "$m"; done' \
  2>/dev/null || echo "WARNING: could not load the lxc kernel modules on Proxmox."

# bulk (hdd) stays disabled in proxmox: pvestatd polls enabled storages every 10s, which keeps the disk
# spinning; vm-109's hookscript enables it only around its own start and stop
"${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
  "set -e; nas=$NAS_ID"'
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
   qm config $nas | grep -q "^hookscript: local:snippets/homelab-bulk.sh" || qm set $nas --hookscript local:snippets/homelab-bulk.sh >/dev/null
   [ "$(qm status $nas | cut -d" " -f2)" = running ] && pvesm set bulk --disable 1
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
if ! "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f /var/lib/vz/template/iso/nixos.img" 2>/dev/null; then
  [ -f "$ROOT_DIR/images/nixos.img" ] || { echo "ERROR: Golden image missing. Run: sudo nix build ./src#cloud-image"; exit 1; }
  echo ">>> Uploading golden image..."
  scp -P "$PROXMOX_SSH_PORT" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" -o StrictHostKeyChecking=yes "$ROOT_DIR/images/nixos.img" \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:/var/lib/vz/template/iso/nixos.img"
fi

# lxc template; only seeds new containers, so upload once
LXC_TEMPLATE=/var/lib/vz/template/cache/nixos-homelab.tar.xz
if ! "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "test -f $LXC_TEMPLATE" 2>/dev/null; then
  echo ">>> Building and uploading the LXC template..."
  tarball=$(nix build "$SRC#lxc-template" "${NIX_FEATURES[@]}" --no-link --print-out-paths)
  scp -P "$PROXMOX_SSH_PORT" -o UserKnownHostsFile="$LAB_KNOWN_HOSTS" -o StrictHostKeyChecking=yes "$tarball"/tarball/*.tar.xz \
    "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST:$LXC_TEMPLATE"
fi

# -----------------------------------------------------------------------------
# SSH TO THE LAB: per zone direct where the house lan routes it (a fritzbox static route), else through the router
# bastion; every host key checked against src/generated/known_hosts
# -----------------------------------------------------------------------------
SSH_CONFIG="$(mktemp --suffix=.ssh_config)"; CLEANUP_FILES+=("$SSH_CONFIG")
: > "$SSH_CONFIG"
# the zone's gateway answers ssh on the router's wan side whenever the zone is routed here
for gateway in $(jq -r '[.[] | select(.type != "router") | .gateway] | unique | .[]' "$INVENTORY"); do
  zone="${gateway%.*}.*"
  if timeout "$ROUTE_PROBE_TIMEOUT_S" bash -c "echo > /dev/tcp/$gateway/22" 2>/dev/null; then
    echo ">>> $zone directly routable: no bastion."
  else
    echo ">>> $zone not routed from here: through the router bastion."
    printf 'Host %s\n  ProxyCommand %s -F %s -W %%h:%%p root@%s\n' "$zone" "$(command -v ssh)" "$SSH_CONFIG" "$ROUTER_WAN_IP" >> "$SSH_CONFIG"
  fi
done
printf 'Host *\n  UserKnownHostsFile %s\n  StrictHostKeyChecking yes\n  HostKeyAlgorithms ssh-ed25519\n' "$LAB_KNOWN_HOSTS" >> "$SSH_CONFIG"
BASTION_SSHOPTS=(-F "$SSH_CONFIG")
export NIX_SSHOPTS="-F $SSH_CONFIG"

# -----------------------------------------------------------------------------
# TERRAFORM
# -----------------------------------------------------------------------------
# idempotent; installs a provider main.tf gained since the last run (the lock file pins it)
terraform -chdir="$TF_DIR" init -input=false > /dev/null
if [ "${TF_STATE_OFFLINE:-0}" = 1 ]; then
  [ -f "$TFSTATE_LOCAL" ] || { echo "ERROR: TF_STATE_OFFLINE=1 needs the local copy $TFSTATE_LOCAL."; exit 1; }
  echo "WARNING: TF_STATE_OFFLINE=1: applying from the local state copy, unlocked; it may be behind the nas."
elif [ "${TF_STATE_FRESH:-0}" = 1 ] && [ ! -f "$TFSTATE_LOCAL" ]; then
  # an empty lab has no nas to lock or pull from
  echo ">>> Terraform state: starting empty (TF_STATE_FRESH=1)."
else
  # the nas guest's own key first: the lock and the state travel over ssh to it
  host_keys_learn "$NAS_ID"
  tfstate_lock_acquire || exit 1
  tfstate_pull || exit 1
fi
# every run, with refresh: proxmox drift (a half-failed apply, a manual edit) is corrected, never trusted
echo ">>> Terraform: applying..."
for i in $(seq 1 "$TF_ATTEMPTS"); do
  terraform -chdir="$TF_DIR" apply -auto-approve -parallelism="$TF_PARALLELISM" -var-file="$PROXMOX_TFVARS" && break
  # a failed apply still writes the state; the apply's failure is the error reported, not the push's
  if [ "$i" -eq "$TF_ATTEMPTS" ]; then
    [ "${TF_STATE_OFFLINE:-0}" = 1 ] || tfstate_push || true
    echo "ERROR: Terraform failed after $TF_ATTEMPTS attempts."; exit 1
  fi
  echo "Retrying ($i/$TF_ATTEMPTS)..."; sleep "$TF_RETRY_S"
done
if [ "${TF_STATE_OFFLINE:-0}" != 1 ]; then
  [ -n "${TFSTATE_LOCK_PID:-}" ] || host_keys_learn "$NAS_ID"
  tfstate_push || DEPLOY_FAILURE=1
fi

# lxc features: root@pam only, so not terraform; a change needs a restart
sorted_features() { tr , '\n' | sort | paste -sd, -; }
for vmid in $(jq -r 'to_entries[] | select(.value.kind == "lxc" and .value.enabled != "false") | .key' "$INVENTORY"); do
  want=$(jq -r --arg id "$vmid" '.[$id].features' "$INVENTORY" | sorted_features)
  # a container terraform has not created reads as no features
  have=$("${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "pct config $vmid 2>/dev/null | sed -n 's/^features: //p'" | sorted_features || true)
  [ "$want" = "$have" ] && continue
  echo ">>> lxc-$vmid features: ${have:-none} -> $want"
  "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
    "pct set $vmid --features $want && if pct status $vmid | grep -q running; then pct reboot $vmid; fi" \
    || echo "WARNING: could not set features on lxc-$vmid"
done

# bpg 0.70 never reads a container's onboot back, so drift there is invisible to terraform: on-demand
# containers must stay off at host boot
for vmid in $(jq -r 'to_entries[] | select(.value.kind == "lxc") | .key' "$INVENTORY"); do
  want=$(jq -r --arg id "$vmid" 'if .[$id].enabled == "true" then 1 else 0 end' "$INVENTORY")
  "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
    "o=\$(pct config $vmid | sed -n 's/^onboot: //p'); [ \"\${o:-0}\" = $want ] || { pct set $vmid --onboot $want && echo '>>> lxc-$vmid onboot -> $want'; }" \
    || echo "WARNING: could not set onboot on lxc-$vmid"
done

# every enabled guest but the router, built and deployed below; its configuration is named like the guest (modules/lab)
mapfile -t GUEST_IDS < <(jq -r 'to_entries[] | select(.value.type != "router" and .value.enabled != "false") | .key' "$INVENTORY")
DISABLED_VMS=$(jq -r '[to_entries[] | select(.value.enabled == "false") | .key] | join(" ")' "$INVENTORY")
if [ -n "$DISABLED_VMS" ]; then echo ">>> Disabled VMs, neither built nor deployed: $DISABLED_VMS"; fi

# the traefiks are always on: pause their reaper before waking anything it could stop again
host_keys_learn "${ONDEMAND_IDS[@]}"
reaper_pause

# enabled vms must run to receive a deploy
mapfile -t ENABLED_IDS < <(jq -r 'to_entries[] | select(.value.enabled != "false") | .key' "$INVENTORY")
if [ "${#ENABLED_IDS[@]}" -gt 0 ]; then
  [ -z "$PROXMOX_API_TOKEN_ID" ] || for vmid in "${ENABLED_IDS[@]}"; do vm_wake "$vmid"; done
  # waits for the guests just started: their agents answer once they are up
  echo ">>> Reading every running guest's host key through Proxmox..."
  host_keys_learn "${ENABLED_IDS[@]}"
fi

# -----------------------------------------------------------------------------
# SECRETS AND BUILD
# -----------------------------------------------------------------------------
# flakes only see git-tracked files
git -C "$ROOT_DIR" add -A src
# every secret, key and rule where the configs just staged say; staged again so the build sees them
HOST_KEYS_FILE=$(umask 077; mktemp --suffix=.host-keys.json); CLEANUP_FILES+=("$HOST_KEYS_FILE")
"$SRC/scripts/secrets-sync.sh" --apply --host-keys-out "$HOST_KEYS_FILE"
git -C "$ROOT_DIR" add -A src .sops.yaml
# the repo is public: stop before anything is built from, or committed with, a plaintext secret
git -C "$ROOT_DIR" config core.hooksPath .githooks
"$SRC/scripts/secrets-check.sh" --require-values

# one nix process for every closure: one per vm ran the workstation out of memory
echo ">>> Building all VM closures..."
BUILD_LOG=$(mktemp --suffix=.build.log); CLEANUP_FILES+=("$BUILD_LOG")
# out links are gc roots until the deploys are done
BUILD_DIR=$(mktemp -d --suffix=.build); CLEANUP_FILES+=("$BUILD_DIR")
BUILD_NAMES=(); BUILD_TARGETS=()
for vm_id in "${GUEST_IDS[@]}"; do
  name=$(name_of "$vm_id")
  BUILD_NAMES+=("$name")
  BUILD_TARGETS+=("$SRC#nixosConfigurations.${name}.config.system.build.toplevel")
done
BUILD_PID=""
if [ "${#BUILD_TARGETS[@]}" -gt 0 ]; then
  nix build "${BUILD_TARGETS[@]}" "${NIX_FEATURES[@]}" \
    --keep-going --out-link "$BUILD_DIR/result" > "$BUILD_LOG" 2>&1 &
  BUILD_PID=$!
fi

# -----------------------------------------------------------------------------
# DEPLOY
# -----------------------------------------------------------------------------
# router first, it is the ssh bastion
deploy_nixos "300-router" "$ROUTER_WAN_IP" || { echo "WARNING: Router deploy failed"; DEPLOY_FAILURE=1; }

if [ "$DEPLOY_FAILURE" -eq 0 ]; then
  echo ">>> Waiting for router bastion..."
  wait_for_ssh "$ROUTER_WAN_IP" "$ROUTER_WAIT_ATTEMPTS" || { echo "ERROR: Router unreachable after deploy."; exit 1; }

  # a wait, not a gate: a guest behind it that stays unreachable fails its own deploy
  echo ">>> Verifying bastion -> internal subnet..."
  wait_for_ssh "$(ip_of "$INGRESS_ID")" "$INGRESS_WAIT_ATTEMPTS" || true

  echo ">>> Verifying router DNS..."
  for _ in $(seq 1 "$DNS_WAIT_ATTEMPTS"); do
    lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$ROUTER_WAN_IP" \
      "dig +short +timeout=2 $DNS_PROBE_NAME @127.0.0.1 2>/dev/null | grep -q ." 2>/dev/null && break
    sleep "$DNS_WAIT_INTERVAL_S"
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
MAX_PARALLEL="${HOMELAB_PARALLEL:-$DEPLOY_PARALLEL_DEFAULT}"
# pid -> instance name of every deploy still running
declare -A DEPLOYING=()

# deploy_reap: block until one running deploy ends, and record its failure
deploy_reap() {
  local pid rc=0
  wait -n -p pid "${!DEPLOYING[@]}" || rc=$?
  [ "$rc" = 0 ] || { echo "WARNING: Failed to deploy ${DEPLOYING[$pid]}"; DEPLOY_FAILURE=1; }
  unset "DEPLOYING[$pid]"
}

echo ">>> Deploying VMs (up to $MAX_PARALLEL in parallel)..."
for vm_id in "${GUEST_IDS[@]}"; do
  name=$(name_of "$vm_id")
  ip=$(ip_of "$vm_id")
  [ -n "$ip" ] || { echo ">>> WARNING: No IP for $name, skipping."; continue; }
  while [ "${#DEPLOYING[@]}" -ge "$MAX_PARALLEL" ]; do deploy_reap; done
  # the reaper may have stopped it meanwhile
  [ -z "$PROXMOX_API_TOKEN_ID" ] || vm_wake "$vm_id"
  deploy_nixos "$name" "$ip" &
  DEPLOYING[$!]=$name
done
while [ "${#DEPLOYING[@]}" -gt 0 ]; do deploy_reap; done

# -----------------------------------------------------------------------------
# COMMIT: what was deployed, even on partial failure. Tracked changes anywhere (a generation never pairs new configs
# with an old sync.sh) and new files under src only: an untracked file elsewhere is never swept into the public repo
# -----------------------------------------------------------------------------
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT_DIR" add -u
  git -C "$ROOT_DIR" add -A src .sops.yaml
  if git -C "$ROOT_DIR" diff --cached --quiet; then
    :
  elif "$SRC/scripts/secrets-check.sh" --require-values; then
    # every commit is Generation: <n>, numbered by position
    next=$(( $(git -C "$ROOT_DIR" rev-list --count HEAD) + 1 ))
    echo ">>> Git: committing generation $next"
    git -C "$ROOT_DIR" commit -m "Generation: $next"
    git -C "$ROOT_DIR" push || echo "WARNING: git push failed."
  else
    echo "ERROR: not committed: the staged tree would publish a secret (above). Unstage or encrypt it, then commit."
    DEPLOY_FAILURE=1
  fi
fi

[ "$DEPLOY_FAILURE" -ne 0 ] && { echo "ERROR: One or more deployments or the commit failed."; exit 1; }
echo ">>> LAB IS FULLY SYNCHRONIZED"
