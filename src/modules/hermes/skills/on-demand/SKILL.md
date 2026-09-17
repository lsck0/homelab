---
name: on-demand
description: Explain and control on-demand VMs and cooldowns.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, OnDemand, Power]
    related_skills: [homelab-ops]
---

# On-demand VMs

VMs with `enabled = "onDemand"` in `src/instances.tf` sleep until used:

- Traefik (vm-100 internal, vm-200 external) holds a socket proxy per route
  (`systemctl status ondemand-<route>` there). The first connection boots the VM
  through the Proxmox API and is held until the app answers.
- After `cooldown` (instances.tf, e.g. `30m`, Minecraft `15m`) without
  connections the proxy exits and the VM is shut down.
- `ondemand-reaper.timer` (every 2 min) also shuts down VMs that were started
  another way (deploy, `vm start`) and never got a connection within the cooldown.

## Tasks

- Which VMs are on demand: `AGENTS.md` (enabled column).
- Use one now: `vm start <id>`; it goes back to sleep after the cooldown.
- Keep one awake for a while: keep a connection open, or start it again later.
- Why did it not wake? On the Traefik VM: `journalctl -u ondemand-<route> -n 50`
  (wake script logs the Proxmox status and readiness wait).
- Change cooldown or make a VM always-on: edit `enabled`/`cooldown` in
  `src/instances.tf`; tell the owner (applied by `sync.sh`).
