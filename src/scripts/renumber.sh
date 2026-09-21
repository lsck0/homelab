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
#   3. destroys the VMs removed from instances.tf (REMOVED, empty in this
#      migration), so their ids can be reused
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
FROM_STEP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    # resume after an interrupted run; steps 1-4 must never run twice, ids are reused
    --from-step) FROM_STEP="${2:?--from-step needs a number}"; shift ;;
    *) echo "usage: $0 [--execute] [--from-step N]"; exit 1 ;;
  esac
  shift
done

# old new
#
# Current migration: 116 was freed for 116-internal-github-runner, which has to
# sit directly after the Forgejo runner (115), so every internal VM from the old
# registry (116) upwards moves one place up. Highest id first, and the script
# routes every rename through a temporary 9xxx id anyway, so the shift cannot
# collide with itself.
#
# 116 itself is not listed: it is a brand-new VM with no disk to rename, and
# sync.sh creates it afterwards.
MAP="
136 137
135 136
134 135
133 134
132 133
131 132
130 131
129 130
128 129
127 128
126 127
125 126
124 125
123 124
122 123
121 122
120 121
119 120
118 119
117 118
116 117
"
REMOVED=""
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
    export SSHPASS="$PVE_PASS"; PVE=(sshpass -e ssh -n -o StrictHostKeyChecking=accept-new "root@$PVE_HOST")
  else
    PVE=(ssh -n -o StrictHostKeyChecking=accept-new "root@$PVE_HOST")
  fi
else
  PVE=(ssh "root@<proxmox>")
fi
VMSSH=(ssh -n -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes)
pve() { run "${PVE[@]}" "$@"; }
pve_out() { [ "$EXECUTE" = 1 ] && "${PVE[@]}" "$@" || true; }
# dry run: pretend every VM exists so the whole plan is printed
exists_on_pve() { [ "$EXECUTE" = 1 ] || return 0; "${PVE[@]}" qm status "$1" >/dev/null 2>&1; }
# never started by this script: rebinding a gpu the host still drives can take the whole host down
has_hostpci() { [ "$EXECUTE" = 1 ] || return 1; "${PVE[@]}" "grep -q '^hostpci' /etc/pve/qemu-server/$1.conf"; }

echo ">>> Renumbering plan (old -> new):"
while read -r old new <&3; do
  [ -n "$old" ] || continue
  printf '    %s -> %s  %s\n' "$old" "$new" "$(name_of "$new")"
done 3<<< "$MAP"
# `&& echo` alone would make an empty REMOVED a failed command under set -e.
if [ -n "$REMOVED" ]; then echo "    destroy: $REMOVED (removed from instances.tf)"; fi

if [ "$EXECUTE" = 1 ]; then
  echo
  echo "This stops the whole lab${REMOVED:+, destroys VMs $REMOVED} and renames VM disks on Proxmox."
  read -r -p "Type 'renumber' to continue: " answer
  [ "$answer" = renumber ] || { echo "Aborted."; exit 1; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. NEW CONFIGS AS NEXT BOOT GENERATION
# ─────────────────────────────────────────────────────────────────────────────
if [ "$FROM_STEP" -le 1 ]; then
echo ">>> 1. Installing new configs (next boot) at the old addresses"
while read -r old new <&3; do
  [ -n "$old" ] || continue
  name=$(name_of "$new"); oldip=$(ip_of "$old")
  if [ "$EXECUTE" = 1 ] && ! exists_on_pve "$old"; then
    echo "    $name: vm $old does not exist on Proxmox, created later by sync.sh"; continue
  fi
  if has_hostpci "$old"; then
    echo "    $name: vm $old has pci passthrough, only renamed; deploy it with sync.sh once passthrough works"; continue
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
done 3<<< "$MAP"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. STOP
# ─────────────────────────────────────────────────────────────────────────────
if [ "$FROM_STEP" -le 2 ]; then
echo ">>> 2. Shutting down renumbered VMs"
while read -r old _ <&3; do
  [ -n "$old" ] || continue
  pve "qm shutdown $old --timeout 180 || qm stop $old || true"
done 3<<< "$MAP"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. REMOVED VMS
# ─────────────────────────────────────────────────────────────────────────────
if [ "$FROM_STEP" -le 3 ]; then
echo ">>> 3. Destroying removed VMs"
for id in $REMOVED; do
  pve "qm stop $id 2>/dev/null; qm destroy $id --purge 2>/dev/null || true"
done
fi

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
if [ "$FROM_STEP" -le 4 ]; then
echo ">>> 4. Renaming VMs on Proxmox (via temporary ids 9xxx)"
while read -r old new <&3; do [ -n "$old" ] && pve "$RENAME_FN renum $old 9$new"; done 3<<< "$MAP"
while read -r old new <&3; do [ -n "$old" ] && pve "$RENAME_FN renum 9$new $new"; done 3<<< "$MAP"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. TERRAFORM STATE
# ─────────────────────────────────────────────────────────────────────────────
# every renumbered VM must now exist under its new id and nothing under its old
# one; importing before that would attach the wrong VMs to the new keys
if [ "$EXECUTE" = 1 ]; then
  bad=""
  new_ids=" $(awk 'NF {printf "%s ", $2}' <<< "$MAP")"
  while read -r old new <&3; do
    [ -n "$old" ] || continue
    exists_on_pve "$new" || bad="$bad missing:$new"
    # an old id that is also some other VM's new id is supposed to exist
    case "$new_ids" in *" $old "*) continue ;; esac
    ! exists_on_pve "$old" || bad="$bad still-old:$old"
  done 3<<< "$MAP"
  [ -z "$bad" ] || { echo "ERROR: rename incomplete:$bad. Terraform state untouched."; exit 1; }
fi

echo ">>> 5. Rewriting Terraform state"
TF=(terraform -chdir="$SRC")
# one rollback copy per migration, stamped. `--from-step` re-runs of the SAME
# migration must not overwrite it (the state is already partly rewritten by
# then), but a later migration must not silently inherit the previous one's copy
# either - that copy describes ids that no longer exist.
BACKUP="$SRC/terraform.tfstate.pre-renumber-$(date +%Y%m%d)"
if [ -e "$BACKUP" ]; then
  echo "    keeping the existing rollback copy $(basename "$BACKUP")"
else
  run cp "$SRC/terraform.tfstate" "$BACKUP"
fi
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
    echo "state is in src/terraform.tfstate.pre-renumber-<date>."
    exit 1
  fi
else
  run "${TF[@]}" plan "# abort if any VM would be destroyed or replaced"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. START
# ─────────────────────────────────────────────────────────────────────────────
echo ">>> 6. Starting VMs with their new ids"
start_failed=""
while read -r _ new <&3; do
  [ -n "$new" ] || continue
  state=$(jq -r --arg id "$new" '.[$id].enabled' "$SRC/inventory.json")
  [ "$state" = false ] && continue
  has_hostpci "$new" && { echo "    vm $new has pci passthrough, not started"; continue; }
  # one VM that does not start (e.g. gpu passthrough not ready) must not leave the rest down
  pve "qm start $new" || start_failed="$start_failed $new"
done 3<<< "$MAP"
[ -z "$start_failed" ] || echo "WARNING: could not start:$start_failed (check with qm start <id> on the host)"

echo ">>> Done. Run ./sync.sh (router + all VMs get their final config; onDemand VMs power off after their cooldown)."
