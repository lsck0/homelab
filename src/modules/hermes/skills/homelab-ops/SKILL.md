---
name: homelab-ops
description: Operate the homelab VMs, services and Proxmox.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Proxmox, NixOS, SSH, Operations]
    related_skills: [minecraft, backups, media, bills]
---

# Homelab operations

You have root on every VM and on the Proxmox host. Read `AGENTS.md` in your
working directory first: it has the VM inventory, IPs, hostnames and rules.

## Tools (run with `terminal`)

- `vm list`: every VM with power state.
- `vm start <id>`: start a VM and wait until SSH answers. Use this before
  talking to an on-demand VM (enabled = onDemand); it powers off again by
  itself after its cooldown.
- `vm stop <id>` / `vm reboot <id>`.
- `ssh <ip> <command>`: root on any VM (10.100.0.<id> internal,
  10.200.0.<id> external). `ssh 192.168.178.200` is the Proxmox host (`qm`, `pvesh`).
- `pve <METHOD> <path> [curl args]`, Proxmox API, e.g.
  `pve GET /nodes/luca-server/qemu/208/status/current`.
- `lab-token <name>`, API keys the VMs export: `radarr-key`, `sonarr-key`,
  `lidarr-key`, `bookshelf-key`, `prowlarr-key`, `jellyfin-key`,
  `jellyseerr-key`, `bazarr-key`, `paperless-key`, `firefly-token`, ... (`lab-token` alone lists them).

## Services

- Containers run under podman: `ssh <ip> podman ps`, `podman logs --tail 100 <name>`,
  `systemctl restart podman-<name>`.
- Logs of every VM are in Loki: `curl -sG http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-208"}' --data-urlencode limit=50`
  or `ssh <ip> journalctl -u <unit> -n 100`.
- Alerts go to ntfy; metrics in Prometheus on 10.100.0.105:9090.

## Rules

- NixOS config is declarative (git repo `homelab`, deployed by `sync.sh` from
  the owner's PC). Changes you make to /etc or units on a VM are lost on the
  next deploy. Runtime state (data dirs, app settings via their APIs, files on
  the NAS) persists. When a change must be permanent in Nix, do the runtime fix
  and tell the owner which file under `src/` needs the same change.
- Before destructive actions (deleting data, restoring backups over live data,
  wiping a VM) state what you will do in one line, then do it. The owner
  granted full access; do not ask for confirmation on routine operations.
- Never print secrets or tokens into the chat.
