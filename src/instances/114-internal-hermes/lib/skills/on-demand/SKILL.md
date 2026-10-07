---
name: on-demand
description: Explain and control on-demand VMs and their idle times.
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

Guests whose `instance.nix` sets `idle.stopAfter` (and apps whose `app.nix` does) sleep until used:

- Traefik (vm-100 internal, vm-200 external) holds a socket proxy per route
  (`systemctl status ondemand-<route>` there). The first connection boots the VM
  through the Proxmox API and is held until the app answers.
- Each side has its own token (`wake-internal@pve`, `wake-external@pve`) that can only see, start and shut down
  the idle guests of its zone (a Proxmox permission per guest, which Terraform derives from the instances). The token
  reaches curl in a header file, and the API's certificate is checked against the Proxmox root ca.
- `sync.sh` pauses the reaper and the idle shutdowns while it deploys (`/run/ondemand-reaper-pause-until`).
- After `idle.stopAfter` without connections the proxy exits and the VM is shut down; an app is scaled to zero
  through its manager's controller instead, and woken the same way.
- `ondemand-reaper.timer` (every 2 min) also shuts down VMs that were started
  another way (deploy, `vm start`) and never got a connection within their idle time.

## Tasks

- Which VMs are on demand: `AGENTS.md` (power column, `idle after <time>`).
- Use one now: the owner starts it (`vm start <id>`); it goes back to sleep after its idle time.
- Keep one awake for a while: keep a connection open, or start it again later.
- Why did it not wake? On the Traefik VM: `journalctl -u ondemand-<route> -n 50`
  (wake script logs the Proxmox status and readiness wait).
- Change the idle time or make a VM always-on: edit `idle` in its
  `src/instances/<folder>/instance.nix`; tell the owner (applied by `sync.sh`).
