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
# env: TF_STATE_FRESH=1    first deploy of an empty lab (after deinit.sh too): no nas to pull from, a local state copy
#                          is set aside
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
tools_require git jq sops ssh ssh-keygen ssh-agent ssh-add terraform nix curl openssl ip

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
# the guests, collected by nix from src/instances/ and src/apps/swarm.nix (modules/lab); filled below
INVENTORY=""
# the desktop clients' interface (modules/lab-export.nix), written below and committed with the generation; the
# lab facts below are read from it
LAB_EXPORT="$SRC/generated/lab.json"
ROUTER_WAN_IP=$(jq -r .lan.router "$LAB_SITE")
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
# a switch still running after this hangs (a hard nfs mount, a unit that never settles): the deploy fails and the run
# goes on to release the state lock and the reaper; half an hour leaves room for the image pulls a switch waits on
SWITCH_TIMEOUT_S=1800
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
# a fetch or push github does not answer within this gives up; the next run catches up
GIT_TIMEOUT_S=60
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

REAPER_PAUSE_FILE=/run/ondemand-reaper-pause-until
# outlives any sync, expires on its own if the trap never runs
REAPER_PAUSE_SECONDS=14400
REAPER_PAUSED=0
# {"<instance>": "<its age key>"}, from secrets-sync.sh: each host gets its own key, never the admin key
HOST_KEYS_FILE=""
HOST_AGE_KEY_PATH=/var/lib/sops-nix/key.txt
# terraform's state lives on the nas, which kopia snapshots; lib/tfstate.sh's TFSTATE_LOCAL is the working copy, and
# TF_DATA_DIR beside it holds the providers: both outside the flake tree, which a path: evaluation copies whole into
# the world-readable store
TF_DIR="$SRC/terraform"
export TF_DATA_DIR="$TFSTATE_DIR/data"
# where the working copy lived until it moved out of the flake tree; moved once, never deleted
TFSTATE_LEGACY_DIR="$SRC/generated/terraform"
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
# the ingresses run the on-demand reaper, which must not shut a guest down mid-deploy
mapfile -t ONDEMAND_IDS < <(jq -r '.zones[].ingress // empty' "$LAB_EXPORT")
# the internal ingress: the first guest reached through the router bastion
INGRESS_ID=$(jq -r .zones.internal.ingress "$LAB_EXPORT")
# the clients hard-mount it: it deploys before them, and it holds the terraform state
NAS_ID=$(jq -r .routes.nas.vmid "$LAB_EXPORT")

echo ">>> SYNCING HARDWARE + OS..."

# abort if behind upstream; github unavailable, the last fetched upstream is the one compared
timeout "$GIT_TIMEOUT_S" git -C "$ROOT_DIR" fetch origin --quiet \
  || echo "WARNING: github unavailable: checked against the upstream as last fetched."
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
  lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$(ip_of "$NAS_ID")" \
    "mkdir -p ${STATE_REMOTE%/*} && { flock -n $STATE_LOCK_REMOTE -c 'echo locked; exec cat >/dev/null' || echo busy; }"
}

pve_api() { curl -sf --cacert "$PVE_CA_FILE" -H @"$PVE_AUTH_FILE" "$@"; }

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

host_age_key_of() {
  local host_key
  host_key=$(jq -r --arg n "$1" '.[$n] // empty' "$HOST_KEYS_FILE")
  [ -n "$host_key" ] || { echo "ERROR: no age key for $1: src/scripts/secrets-sync.sh did not plan it" >&2; return 1; }
  printf '%s\n' "$host_key"
}

# host_age_key_push <name> <ip>: this host's own age key, written ahead of the identities the key file holds when it
# differs, so the running system and the next boot still decrypt until a switch takes it; prints "changed" if it did
host_age_key_push() {
  host_age_key_of "$1" | lab_ssh "root@$2" \
    "install -d -m 700 ${HOST_AGE_KEY_PATH%/*} && umask 077 && cat > $HOST_AGE_KEY_PATH.new \
     && if cmp -s $HOST_AGE_KEY_PATH.new $HOST_AGE_KEY_PATH; then rm $HOST_AGE_KEY_PATH.new; \
        else { cat $HOST_AGE_KEY_PATH.new; grep -vxF -f $HOST_AGE_KEY_PATH.new $HOST_AGE_KEY_PATH || true; } \
               > $HOST_AGE_KEY_PATH.both && mv $HOST_AGE_KEY_PATH.both $HOST_AGE_KEY_PATH \
             && rm $HOST_AGE_KEY_PATH.new && echo changed; fi"
}

# host_age_key_settle <name> <ip>: after a switch that decrypted with it, the key file holds this host's key alone
host_age_key_settle() {
  host_age_key_of "$1" | lab_ssh "root@$2" \
    "umask 077 && cat > $HOST_AGE_KEY_PATH.new && mv $HOST_AGE_KEY_PATH.new $HOST_AGE_KEY_PATH"
}

# switch_failures_real <ip> <switch output>: the units the switch named as failed that the configuration declares;
# a transient unit (podman's healthcheck runs, systemd-run) is no configuration's and fails mid-restart by design;
# one systemd already collected is not found any more, which no declared unit ever is
switch_failures_real() {
  local units
  units=$(sed -n 's/^warning: the following units failed: //p' "$2" | tr ',' ' ')
  [ -n "$units" ] || { echo "the switch itself"; return 0; }
  # shellcheck disable=SC2086 # one word per unit
  lab_ssh -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_S" "root@$1" \
    "for u in $units; do
       if [ \"\$(systemctl show -P Transient \"\$u\")\" = no ] && [ \"\$(systemctl show -P LoadState \"\$u\")\" != not-found ]; then
         echo \"\$u\"
       fi
     done"
}

deploy_nixos() {
  local name="$1" ip="$2"
  echo ">>> Deploying $name to $ip..."
  ssh-keygen -F "$ip" -f "$LAB_KNOWN_HOSTS" >/dev/null \
    || { echo "ERROR: no host key for $name ($ip) in src/generated/known_hosts: the hypervisor could not read it"; return 1; }
  wait_for_ssh "$ip" || return 1

  # the router deploys before the batch build finishes, so it builds its own; a host the batch failed has ""
  local toplevel="${TOPLEVELS[$name]:-}"
  if [ -z "${TOPLEVELS[$name]+batch}" ]; then
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
  timeout "$SWITCH_TIMEOUT_S" ssh "${BASTION_SSHOPTS[@]}" "root@${ip}" \
    "nix-env -p /nix/var/nix/profiles/system --set '${toplevel}' \
     && '${toplevel}/bin/switch-to-configuration' switch" 2>&1 | tee "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 124 ] || { echo "ERROR: $name: the switch did not finish within ${SWITCH_TIMEOUT_S}s."; rm -f "$out"; return 1; }
    failed=$(switch_failures_real "$ip" "$out") || failed="unknown: the guest did not answer"
    rm -f "$out"
    [ -z "$failed" ] || { echo "ERROR: $name: the switch failed: $failed"; return 1; }
    echo ">>> $name: only transient units failed during the switch."
  fi
  rm -f "$out"
  [ "$key_state" != changed ] || host_age_key_settle "$name" "$ip" || return 1
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

PROXMOX_SSH_HOST=$(jq -r .lan.proxmox "$LAB_SITE")
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

# the host as the lab declares it, before terraform needs its bridges, tokens and storage; a token it had to create
# lands in the tfvars and secrets, so the tfvars are read after it
proxmox_converge "$LAB_EXPORT" ""
# terraform and curl verify the api against the cluster CA; the node certificate names the host's address
PVE_CA_FILE=$(mktemp --suffix=.pve-ca.pem); CLEANUP_FILES+=("$PVE_CA_FILE")
proxmox_ca_write "$PVE_CA_FILE"
# terraform runs nix (lib.tf's guests), which keeps the trust it has: nix's own lookup order
NIX_TRUST="${NIX_SSL_CERT_FILE:-${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}}"
# the proxmox firewall admits the api from the owner's machines only (terraform/lib.tf, operators)
OPERATOR_IP=$(ip -4 route get "$PROXMOX_SSH_HOST" | sed -n 's/.* src \([0-9.]*\).*/\1/p')
jq -e --arg ip "$OPERATOR_IP" '[.lan.workstation, .lan.notebook] | index($ip)' "$LAB_SITE" >/dev/null || {
  echo "ERROR: this machine reaches Proxmox from $OPERATOR_IP, which is neither site.json's lan.workstation nor lan.notebook:"
  echo "       the Proxmox firewall drops its api calls. Deploy from one of them, or rerun src/scripts/init.sh here."
  exit 1
}
PROXMOX_API_TOKEN_ID="$(proxmox_tfvar_read proxmox_api_token_id)"
PROXMOX_API_TOKEN_SECRET="$(proxmox_tfvar_read proxmox_api_token_secret)"
PROXMOX_NODE=$(jq -r .node "$LAB_SITE")
PVE_API="https://$PROXMOX_SSH_HOST:$PVE_API_PORT/api2/json"
# a header file, out of argv
PVE_AUTH_FILE=$(umask 077; mktemp); CLEANUP_FILES+=("$PVE_AUTH_FILE")
printf 'Authorization: PVEAPIToken=%s=%s\n' "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET" > "$PVE_AUTH_FILE"
unset PROXMOX_API_TOKEN_SECRET
pve_api "$PVE_API/version" >/dev/null \
  || { echo "ERROR: the Proxmox api refused the token, or its certificate does not chain to site.json's proxmoxCa."; exit 1; }

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
printf 'Host *\n  UserKnownHostsFile %s\n  StrictHostKeyChecking yes\n  HostKeyAlgorithms ssh-ed25519\n  ServerAliveInterval %s\n  ServerAliveCountMax %s\n' \
  "$LAB_KNOWN_HOSTS" "$PROXMOX_SSH_ALIVE_INTERVAL_S" "$PROXMOX_SSH_ALIVE_COUNT" >> "$SSH_CONFIG"
BASTION_SSHOPTS=(-F "$SSH_CONFIG")
export NIX_SSHOPTS="-F $SSH_CONFIG"

# -----------------------------------------------------------------------------
# TERRAFORM
# -----------------------------------------------------------------------------
if [ -d "$TFSTATE_LEGACY_DIR" ] && [ ! -e "$TFSTATE_DIR" ]; then
  echo ">>> Terraform state: moving the working copy out of the flake tree to $TFSTATE_DIR"
  install -d -m 700 "${TFSTATE_DIR%/*}"
  cp -a "$TFSTATE_LEGACY_DIR" "$TFSTATE_DIR.moved-from-src"
  mv "$TFSTATE_LEGACY_DIR" "$TFSTATE_DIR"
  chmod -R go= "$TFSTATE_DIR" "$TFSTATE_DIR.moved-from-src"
fi
install -d -m 700 "$TFSTATE_DIR"
# idempotent; installs a provider main.tf gained since the last run (the lock file pins it)
# -reconfigure: the path is the only backend setting, and the state already lives there (moved above)
terraform -chdir="$TF_DIR" init -input=false -reconfigure -backend-config="path=$TFSTATE_LOCAL" > /dev/null
if [ "${TF_STATE_OFFLINE:-0}" = 1 ]; then
  [ -f "$TFSTATE_LOCAL" ] || { echo "ERROR: TF_STATE_OFFLINE=1 needs the local copy $TFSTATE_LOCAL."; exit 1; }
  echo "WARNING: TF_STATE_OFFLINE=1: applying from the local state copy, unlocked; it may be behind the nas."
elif [ "${TF_STATE_FRESH:-0}" = 1 ]; then
  # an empty lab has no nas to lock or pull from; a copy of an earlier lab would make terraform look for its guests
  tfstate_set_aside
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
  SSL_CERT_FILE="$PVE_CA_FILE" NIX_SSL_CERT_FILE="$NIX_TRUST" terraform -chdir="$TF_DIR" apply -auto-approve -parallelism="$TF_PARALLELISM" \
    -var-file="$PROXMOX_TFVARS" && break
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

# the anti-spoofing every source-address guard of the lab relies on (terraform/lib.tf FIREWALL)
"${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" "pve-firewall status" | grep -qx 'Status: enabled/running' \
  || { echo "ERROR: the Proxmox firewall is not running: every guest can take a neighbour's address."; DEPLOY_FAILURE=1; }

# what terraform's token may not set (root@pam only): lxc features (a change restarts the container) and lxc onboot
# (bpg 0.70 never reads it back, so drift there is invisible to terraform; on-demand containers stay off at host
# boot); a guest that does not take them fails the deploy
GUEST_SETTINGS_REMOTE=$(cat <<'REMOTE'
set -euo pipefail
sorted() { tr , '\n' | sort | paste -sd, -; }
while read -r id features onboot; do
  config=$(pct config "$id")
  have=$(sed -n 's/^features: //p' <<<"$config" | sorted)
  if [ "$(sorted <<<"$features")" != "$have" ]; then
    echo ">>> lxc-$id features: ${have:-none} -> $features"
    pct set "$id" --features "$features"
    if pct status "$id" | grep -q running; then pct reboot "$id"; fi
  fi
  if [ "$(sed -n 's/^onboot: //p' <<<"$config")" != "$onboot" ]; then
    pct set "$id" --onboot "$onboot"
    echo ">>> lxc-$id onboot -> $onboot"
  fi
done
REMOTE
)
jq -r 'to_entries[] | select(.value.kind == "lxc") | "\(.key) \(.value.features) \(if .value.powered and .value.idle == null then 1 else 0 end)"' "$INVENTORY" \
  | "${PROXMOX_SSH[@]}" "$PROXMOX_SSH_USER@$PROXMOX_SSH_HOST" \
      "bash -c $(printf %q "$GUEST_SETTINGS_REMOTE")" \
  || { echo "ERROR: Proxmox did not take the guests' root-only settings (above)."; DEPLOY_FAILURE=1; }

# every powered guest but the router, built and deployed below; its configuration is named like the guest (modules/lab)
mapfile -t GUEST_IDS < <(jq -r 'to_entries[] | select(.value.type != "router" and .value.powered) | .key' "$INVENTORY")
UNPOWERED_IDS=$(jq -r '[to_entries[] | select(.value.powered | not) | .key] | join(" ")' "$INVENTORY")
if [ -n "$UNPOWERED_IDS" ]; then echo ">>> Powered-off VMs, neither built nor deployed: $UNPOWERED_IDS"; fi

# the traefiks are always on: pause their reaper before waking anything it could stop again
host_keys_learn "${ONDEMAND_IDS[@]}"
reaper_pause

# powered vms must run to receive a deploy
mapfile -t POWERED_IDS < <(jq -r 'to_entries[] | select(.value.powered) | .key' "$INVENTORY")
if [ "${#POWERED_IDS[@]}" -gt 0 ]; then
  for vmid in "${POWERED_IDS[@]}"; do vm_wake "$vmid"; done
  # waits for the guests just started: their agents answer once they are up
  echo ">>> Reading every running guest's host key through Proxmox..."
  host_keys_learn "${POWERED_IDS[@]}"
fi

# -----------------------------------------------------------------------------
# SECRETS AND BUILD
# -----------------------------------------------------------------------------
# flakes see git-tracked files only: tracked changes and what this run generates are staged, nothing else, so a stray
# file under src never reaches the public repo; a new instance or app folder is `git add`ed by its author
stage_declared() {
  git -C "$ROOT_DIR" add -u
  git -C "$ROOT_DIR" add -A -- .sops.yaml src/generated ':(glob)src/**/age.pub' ':(glob)src/**/age.sops' ':(glob)src/**/*.sops.json'
}
stage_declared
# every secret, key and rule where the configs say; staged again so the build sees them
HOST_KEYS_FILE=$(umask 077; mktemp --suffix=.host-keys.json); CLEANUP_FILES+=("$HOST_KEYS_FILE")
"$SRC/scripts/secrets-sync.sh" --apply --host-keys-out "$HOST_KEYS_FILE"
stage_declared
UNTRACKED=$(git -C "$ROOT_DIR" ls-files --others --exclude-standard -- src)
[ -z "$UNTRACKED" ] || printf 'WARNING: untracked, neither built nor committed (git add what belongs to the lab):\n%s\n' "$UNTRACKED"
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
BUILD_RC=0
if [ -n "$BUILD_PID" ]; then wait "$BUILD_PID" || BUILD_RC=$?; fi
cat "$BUILD_LOG"
if [ "$BUILD_RC" = 0 ]; then
  # nix names the out link of installable i result-i, the first plain result
  for i in "${!BUILD_NAMES[@]}"; do
    link="$BUILD_DIR/result"; [ "$i" -gt 0 ] && link="$link-$i"
    TOPLEVELS[${BUILD_NAMES[$i]}]=$(readlink -f "$link")
  done
  echo ">>> All builds complete."
else
  # a fetch that failed (a registry or github unavailable) fails only the hosts needing it; nix links no result once
  # any build failed, so the toplevels that did build are looked up in the store
  echo "ERROR: not every closure built (above): the hosts whose closure did are deployed, the others fail."
  DEPLOY_FAILURE=1
  names_json=$(printf '%s\n' "${BUILD_NAMES[@]}" | jq -R . | jq -sc .)
  mapfile -t BUILT < <(nix eval "${NIX_FEATURES[@]}" --json --no-warn-dirty "$SRC#nixosConfigurations" \
    --apply "cs: map (n: cs.\${n}.config.system.build.toplevel.outPath) (builtins.fromJSON ''$names_json'')" | jq -r '.[]')
  for i in "${!BUILD_NAMES[@]}"; do
    TOPLEVELS[${BUILD_NAMES[$i]}]=""
    if [ -e "${BUILT[$i]:-}" ]; then TOPLEVELS[${BUILD_NAMES[$i]}]=${BUILT[$i]}; fi
  done
fi

# the nas next, alone: its clients hard-mount it, and a switch of theirs blocks on a nas that restarts under it
deploy_nixos "$(name_of "$NAS_ID")" "$(ip_of "$NAS_ID")" || { echo "WARNING: Failed to deploy $(name_of "$NAS_ID")"; DEPLOY_FAILURE=1; }

# the rest in parallel
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
  [ "$vm_id" != "$NAS_ID" ] || continue
  name=$(name_of "$vm_id")
  ip=$(ip_of "$vm_id")
  [ -n "$ip" ] || { echo ">>> WARNING: No IP for $name, skipping."; continue; }
  while [ "${#DEPLOYING[@]}" -ge "$MAX_PARALLEL" ]; do deploy_reap; done
  # the reaper may have stopped it meanwhile
  vm_wake "$vm_id"
  deploy_nixos "$name" "$ip" &
  DEPLOYING[$!]=$name
done
while [ "${#DEPLOYING[@]}" -gt 0 ]; do deploy_reap; done

# -----------------------------------------------------------------------------
# COMMIT: what was deployed, even on partial failure: tracked changes anywhere (a generation never pairs new configs
# with an old sync.sh) and what the run generated
# -----------------------------------------------------------------------------
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  stage_declared
  if git -C "$ROOT_DIR" diff --cached --quiet; then
    :
  elif "$SRC/scripts/secrets-check.sh" --require-values; then
    # every commit is Generation: <n>, numbered by position
    next=$(( $(git -C "$ROOT_DIR" rev-list --count HEAD) + 1 ))
    echo ">>> Git: committing generation $next"
    git -C "$ROOT_DIR" commit -m "Generation: $next"
    # the next run pushes what this one could not
    timeout "$GIT_TIMEOUT_S" git -C "$ROOT_DIR" push || echo "WARNING: github unavailable: the generation is not pushed yet."
  else
    echo "ERROR: not committed: the staged tree would publish a secret (above). Unstage or encrypt it, then commit."
    DEPLOY_FAILURE=1
  fi
fi

[ "$DEPLOY_FAILURE" -ne 0 ] && { echo "ERROR: One or more deployments or the commit failed."; exit 1; }
echo ">>> LAB IS FULLY SYNCHRONIZED"
