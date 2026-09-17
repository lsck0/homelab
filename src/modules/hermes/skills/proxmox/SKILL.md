---
name: proxmox
description: Manage Proxmox VMs, snapshots and the host.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Proxmox, VM]
    related_skills: [homelab-ops]
---

# Proxmox (host 192.168.178.200, node `luca-server`)

VM ids, names and IPs: `AGENTS.md`. Power actions: `vm` (see `homelab-ops`).
Everything else with `terminal` on the host: `ssh 192.168.178.200 <cmd>`.

## Common tasks

- Overview: `ssh 192.168.178.200 'qm list'`, host load `pvesh get /nodes/luca-server/status --output-format json`.
- VM config: `qm config <id>`; live resource use: `pvesh get /nodes/luca-server/qemu/<id>/status/current --output-format json`.
- Snapshot before a risky change: `qm snapshot <id> pre-<what>-$(date +%F)`;
  list `qm listsnapshot <id>`; roll back `qm rollback <id> <snap>` (VM must be stopped
  for RAM-less snapshots); delete `qm delsnapshot <id> <snap>`.
- Whole-VM backups (vzdump) are not scheduled any more (they filled the host root disk); NAS data is in Kopia. Old dumps, if any:
  `pvesh get /cluster/backup`, files in `/var/lib/vz/dump/`. Restore a VM image:
  `qmrestore /var/lib/vz/dump/<file> <id> --force` (destroys current disk; NAS data is separate).
- Console when SSH is dead: `qm guest exec <id> -- <cmd>` (QEMU guest agent) or `qm terminal <id>`.
- Storage: `pvesm status`; disk health `smartctl -a /dev/sda`.
- GPU passthrough (vm-113): mapping `gpu` = 10de:1f08 at 0000:2b:00.0, `lspci -nnk -s 2b:00.0` must show `vfio-pci`.

## Rules

- VM definitions (CPU, RAM, disk, enabled/onDemand) are Terraform in
  `src/instances.tf` of the homelab repo. `qm set` changes drift until the next
  `sync.sh`; tell the owner the matching instances.tf edit.
- Never `qm destroy` or touch the host network config without the owner asking.
