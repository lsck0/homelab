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

- Overview: `ssh 192.168.178.200 'qm list; pct list'` (the lxc guests of the lab inventory, `nix eval ./src#lab.inventory`, are containers: `pct` instead of `qm`), host load `pvesh get /nodes/luca-server/status --output-format json`.
- VM config: `qm config <id>`; live resource use: `pvesh get /nodes/luca-server/qemu/<id>/status/current --output-format json`.
- Snapshot before a risky change: `qm snapshot <id> pre-<what>-$(date +%F)`;
  list `qm listsnapshot <id>`; roll back `qm rollback <id> <snap>` (VM must be stopped
  for RAM-less snapshots); delete `qm delsnapshot <id> <snap>`.
- Whole-VM backups (vzdump) are not scheduled; NAS data is in Kopia. Old dumps, if any:
  `pvesh get /cluster/backup`, files in `/var/lib/vz/dump/`. Restore a VM image:
  `qmrestore /var/lib/vz/dump/<file> <id> --force` (destroys current disk; NAS data is separate).
- Console when SSH is dead: `qm guest exec <id> -- <cmd>` (QEMU guest agent) or `qm terminal <id>`.
- Storage: `pvesm status`; disk health `smartctl -a /dev/sda` (also scraped: debian's smartmon and nvme collectors,
  textfile dir `/var/lib/prometheus/node-exporter`).
- Firewall: the datacenter firewall binds every guest to its own address and mac (ipset `ipfilter-net0` per guest,
  Terraform `src/terraform/lib.tf`); the host keeps ssh, 8006 and 9100 open by explicit rules. A guest that cannot talk at all
  after an address change needs its ipset, which the next `sync.sh` writes. `pve-firewall status`,
  `pve-firewall compile`.
- GPU mapping `gpu` = RTX 2060, 10de:1f08 at 0000:2b:00.0 (`lspci -nnk -s 2b:00.0` shows `vfio-pci`).

## Rules

- VM definitions (CPU, RAM, disk, power, idle) are each guest's `vm` in
  `src/instances/<folder>/instance.nix` of the homelab repo, applied by Terraform. `qm set` changes drift until the
  next `sync.sh`; tell the owner the matching instance.nix edit.
- Never `qm destroy` or touch the host network config without the owner asking.
