#!/bin/bash
# One-time migration: renumber the VMs so ids follow the order in instances.tf.
#
# A VM id is also its IP (10.x.0.<id>) and hostname (vm-<id>), so every
# renumbered VM needs its new NixOS config *before* it boots under the new id,
# and Terraform must not see a changed vm_id (it would destroy and recreate the
# disk). This script, for each VM in MAP:
#
#   1. builds the new configs and installs them on the VM at its OLD address as
#      the next boot generation (`switch-to-configuration boot`, no switch now)
#   2. shuts the VM down
#   3. destroys the VMs removed from instances.tf (110, 132, 135), their ids
#      are reused
#   4. renames the VM on Proxmox in place: disk volumes (LVM/LVM-thin, ZFS, dir)
#      and config, through temporary ids 9xxx so no two VMs collide
#   5. rewrites Terraform state: drops the old addresses and imports every VM
#      at its new id, then refuses to continue if the plan replaces any VM
#   6. starts the VMs again; they boot the installed config with the new IP
#
# Afterwards run ./sync.sh as usual. Dry run by default: prints what it would
# do. Run with --execute to apply. The whole lab is down during steps 2–6.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/src"
EXECUTE=0
[ "${1:-}" = "--execute" ] && EXECUTE=1

# old new
MAP="
128 101
133 102
102 103
103 104
104 105
105 108
131 109
106 110
117 111
127 112
126 113
107 114
108 115
109 116
111 117
112 118
129 119
113 120
125 121
116 122
140 123
115 124
114 125
139 126
136 127
118 128
119 129
120 130
137 131
138 132
121 133
122 134
123 135
124 136
209 202
206 203
202 204
203 205
204 206
205 207
207 208
208 209
"
REMOVED="110 132 135"
NODE=luca-server

ip_of() { if [ "$1" -ge 200 ]; then echo "10.200.0.$1"; else echo "10.100.0.$1"; fi; }
name_of() { jq -r --arg id "$1" '.[$id].name' "$SRC/inventory.json"; }

run() {
  if [ "$EXECUTE" = 1 ]; then "$@"; else printf '    [dry-run] %s\n' "$*"; fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ACCESS
# ─────────────────────────────────────────────────────────────────────────────
TFVARS=$(mktemp --suffix=.tfvars.json); trap 'rm -f "$TFVARS"' EXIT
if [ "$EXECUTE" = 1 ]; then
  SOPS_AGE_KEY_FILE="$ROOT_DIR/secrets/age.txt" sops --decrypt "$SRC/terraform.tfvars.sops.json" > "$TFVARS"
  PVE_HOST=$(jq -r '.proxmox_ssh_host' "$TFVARS")
  PVE_PASS=$(jq -r '.proxmox_ssh_password // empty' "$TFVARS")
  if [ -n "$PVE_PASS" ]; then
    export SSHPASS="$PVE_PASS"; PVE=(sshpass -e ssh -o StrictHostKeyChecking=accept-new "root@$PVE_HOST")
  else
    PVE=(ssh -o StrictHostKeyChecking=accept-new "root@$PVE_HOST")
  fi
else
  PVE=(ssh "root@<proxmox>")
fi
VMSSH=(ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
pve() { run "${PVE[@]}" "$@"; }
pve_out() { [ "$EXECUTE" = 1 ] && "${PVE[@]}" "$@" || true; }

echo ">>> Renumbering plan (old -> new):"
while read -r old new; do
  [ -n "$old" ] || continue
  printf '    %s -> %s  %s\n' "$old" "$new" "$(name_of "$new")"
done <<< "$MAP"
echo "    destroy: $REMOVED (removed from instances.tf)"

if [ "$EXECUTE" = 1 ]; then
  echo
  echo "This stops the whole lab, destroys VMs $REMOVED and renames VM disks on Proxmox."
  read -r -p "Type 'renumber' to continue: " answer
  [ "$answer" = renumber ] || { echo "Aborted."; exit 1; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. NEW CONFIGS AS NEXT BOOT GENERATION
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 1. Installing new configs (next boot) at the old addresses"
exists_on_pve() { pve_out qm status "$1" >/dev/null 2>&1; }
while read -r old new; do
  [ -n "$old" ] || continue
  name=$(name_of "$new"); oldip=$(ip_of "$old")
  if [ "$EXECUTE" = 1 ] && ! exists_on_pve "$old"; then
    echo "    $name: vm $old does not exist on Proxmox, created later by sync.sh"; continue
  fi
  echo "    $name: vm $old ($oldip)"
  if [ "$EXECUTE" = 1 ]; then
    if ! pve_out qm status "$old" | grep -q running; then
      "${PVE[@]}" qm start "$old" || true
    fi
    ok=0
    for _ in $(seq 1 36); do "${VMSSH[@]}" "root@$oldip" true 2>/dev/null && { ok=1; break; }; sleep 5; done
    if [ "$ok" = 0 ]; then
      echo "    WARNING: $oldip unreachable; $name keeps its old config and must be fixed by hand after the move"
      continue
    fi
  fi
  run nix build "$SRC#nixosConfigurations.$name.config.system.build.toplevel" --no-link
  if [ "$EXECUTE" = 1 ]; then
    top=$(nix build "$SRC#nixosConfigurations.$name.config.system.build.toplevel" --no-link --print-out-paths)
    NIX_SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null" \
      nix copy --no-check-sigs --to "ssh-ng://root@$oldip" "$top"
    "${VMSSH[@]}" "root@$oldip" "nix-env -p /nix/var/nix/profiles/system --set '$top' && '$top/bin/switch-to-configuration' boot"
  else
    run nix copy --to "ssh-ng://root@$oldip" "<toplevel>"
    run "${VMSSH[@]}" "root@$oldip" "switch-to-configuration boot"
  fi
done <<< "$MAP"

# ─────────────────────────────────────────────────────────────────────────────
# 2. STOP
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 2. Shutting down renumbered VMs"
while read -r old _; do
  [ -n "$old" ] || continue
  pve "qm shutdown $old --timeout 180 || qm stop $old || true"
done <<< "$MAP"

# ─────────────────────────────────────────────────────────────────────────────
# 3. REMOVED VMS
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 3. Destroying removed VMs"
for id in $REMOVED; do
  pve "qm stop $id 2>/dev/null; qm destroy $id --purge 2>/dev/null || true"
done

# ─────────────────────────────────────────────────────────────────────────────
# 4. RENAME ON PROXMOX
# ─────────────────────────────────────────────────────────────────────────────
# runs on the host. Renames every volume named vm-<old>-* (and LVM snapshot
# volumes snap_vm-<old>-*) on the VM's storages, then the config file.
RENAME_FN='
renum() {
  old=$1 new=$2
  conf=/etc/pve/qemu-server/$old.conf
  [ -f "$conf" ] || { echo "vm $old: no config, skipped"; return 0; }
  [ ! -e /etc/pve/qemu-server/$new.conf ] || { echo "vm $new already exists"; return 1; }
  qm status "$old" | grep -q stopped || { echo "vm $old is not stopped"; return 1; }
  for store in $(grep -oE "^[a-z0-9]+: [A-Za-z0-9_-]+:($old/)?vm-$old-" "$conf" | awk "{print \$2}" | cut -d: -f1 | sort -u); do
    type=$(pvesm status --storage "$store" | awk "NR==2 {print \$2}")
    case "$type" in
      lvmthin|lvm)
        vg=$(awk -v s="$store" "\$2==s {f=1} f && \$1==\"vgname\" {print \$2; exit}" /etc/pve/storage.cfg)
        for lv in $(lvs --noheadings -o lv_name "$vg" | tr -d " " | grep -E "^(snap_)?vm-$old-"); do
          lvrename "$vg" "$lv" "${lv/vm-$old-/vm-$new-}"
        done ;;
      zfspool)
        pool=$(awk -v s="$store" "\$2==s {f=1} f && \$1==\"pool\" {print \$2; exit}" /etc/pve/storage.cfg)
        for ds in $(zfs list -H -o name -r "$pool" | grep -E "/vm-$old-"); do
          zfs rename "$ds" "${ds/vm-$old-/vm-$new-}"
        done ;;
      dir|nfs|cifs)
        base=$(awk -v s="$store" "\$2==s {f=1} f && \$1==\"path\" {print \$2; exit}" /etc/pve/storage.cfg)
        mkdir -p "$base/images/$new"
        for f in "$base/images/$old"/vm-$old-*; do
          mv "$f" "$base/images/$new/$(basename "${f/vm-$old-/vm-$new-}")"
        done
        rmdir "$base/images/$old" 2>/dev/null || true ;;
      *) echo "vm $old: storage $store type $type not supported"; return 1 ;;
    esac
  done
  sed -e "s#:$old/vm-$old-#:$new/vm-$new-#g" -e "s/vm-$old-/vm-$new-/g" "$conf" > "/etc/pve/qemu-server/$new.conf"
  rm "$conf"
  [ -f "/etc/pve/firewall/$old.fw" ] && mv "/etc/pve/firewall/$old.fw" "/etc/pve/firewall/$new.fw"
  echo "vm $old -> $new"
}
'
echo ">>> 4. Renaming VMs on Proxmox (via temporary ids 9xxx)"
while read -r old new; do [ -n "$old" ] && pve "$RENAME_FN renum $old 9$new"; done <<< "$MAP"
while read -r old new; do [ -n "$old" ] && pve "$RENAME_FN renum 9$new $new"; done <<< "$MAP"

# ─────────────────────────────────────────────────────────────────────────────
# 5. TERRAFORM STATE
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 5. Rewriting Terraform state"
TF=(terraform -chdir="$SRC")
run cp "$SRC/terraform.tfstate" "$SRC/terraform.tfstate.pre-renumber"
run "${TF[@]}" init -input=false
for addr in $("${TF[@]}" state list 2>/dev/null | grep -E 'proxmox_virtual_environment_vm' || true); do
  run "${TF[@]}" state rm "$addr"
done
if "${TF[@]}" state list 2>/dev/null | grep -q '^module.instances.proxmox_virtual_environment_hardware_mapping_pci.gpu$'; then
  run "${TF[@]}" state mv module.instances.proxmox_virtual_environment_hardware_mapping_pci.gpu proxmox_virtual_environment_hardware_mapping_pci.gpu
fi
for id in $(jq -r 'keys[]' "$SRC/inventory.json"); do
  if [ "$EXECUTE" = 1 ] && ! exists_on_pve "$id"; then
    echo "    vm $id not on Proxmox yet, sync.sh creates it"; continue
  fi
  run "${TF[@]}" import -input=false -var-file="$TFVARS" "proxmox_virtual_environment_vm.vm[\"$id\"]" "$NODE/$id"
done
if [ "$EXECUTE" = 1 ]; then
  plan=$("${TF[@]}" plan -input=false -no-color -var-file="$TFVARS")
  echo "$plan" | grep -E '^Plan:|will be (created|destroyed)|must be replaced' || true
  if echo "$plan" | grep -qE 'must be replaced|will be destroyed'; then
    echo "ERROR: the plan destroys or replaces a VM. VMs are renamed but stopped; nothing else"
    echo "was changed. Fix the diff (terraform -chdir=src plan) before starting them. The old"
    echo "state is in src/terraform.tfstate.pre-renumber."
    exit 1
  fi
else
  run "${TF[@]}" plan "# abort if any VM would be destroyed or replaced"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. START
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 6. Starting VMs with their new ids"
while read -r _ new; do
  [ -n "$new" ] || continue
  state=$(jq -r --arg id "$new" '.[$id].enabled' "$SRC/inventory.json")
  [ "$state" = false ] && continue
  pve "qm start $new"
done <<< "$MAP"

echo ">>> Done. Run ./sync.sh (router + all VMs get their final config; onDemand VMs power off after their cooldown)."
