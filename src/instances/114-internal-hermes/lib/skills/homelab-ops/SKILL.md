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
working directory first: it has the VM inventory (addresses, enabled state) and
wins over any address or state a skill mentions.

## Tools (run with `terminal`)

- `vm list`: every VM with power state.
- `vm start <id>`: start a VM and wait until SSH answers. Use this before
  talking to a VM whose AGENTS.md state is `onDemand`; it powers off again by
  itself after its cooldown.
- `vm stop <id>` / `vm reboot <id>`.
- `ssh <ip> <command>`: root on any VM (10.100.0.<id> internal, 10.200.0.<id> external,
  10.250.0.<id> apps zone) and on the router (10.100.0.1). `ssh 192.168.178.200` is the Proxmox host (`qm`, `pct`, `pvesh`).
- `pve <get|create|set|delete> <api path> [--<param> <value>...]`: the Proxmox API through `pvesh` on the host,
  JSON out, e.g. `pve get /nodes/luca-server/qemu/208/status/current` (containers: `/lxc/<id>`, see `vm list`).
- `lab-token <name>`: API keys the VMs export, e.g. `radarr-key`, `sonarr-key`, `lidarr-key`, `prowlarr-key`,
  `jellyfin-key-hermes`, `jellyseerr-key`, `bazarr-key`, `paperless-key`, `firefly-token`, `forgejo-hermes`
  (`lab-token` alone lists them).
- `lab-notify`: a push to the owner over ntfy (skill `ntfy`).

## Services

- Containers run under podman: `ssh <ip> podman ps`, `podman logs --tail 100 <name>`,
  `systemctl restart podman-<name>`.
- Logs of every VM are in Loki: `curl -sG http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-208"}' --data-urlencode limit=50`
  or `ssh <ip> journalctl -u <unit> -n 100`.
- Alerts go to ntfy (topic `homelab-alerts`), and to Telegram for rules labeled `notify=telegram`, grouped by
  category (skill `grafana`); metrics in Prometheus on 10.100.0.105:9090.
- Setup units configure an app after it starts and retry every 30 s until they succeed (`<app>-setup`,
  `*-token`); a unit stuck in `activating (auto-restart)` names the reason in its journal.

## Rules

- NixOS config is declarative (git repo `homelab`, deployed by `sync.sh` from
  the owner's PC; you never deploy). Changes you make to /etc or units on a VM are lost on the
  next deploy. Runtime state (data dirs, app settings via their APIs, files on
  the NAS) persists. When a change must be permanent in Nix, do the runtime fix
  and open a pull request for the file under `src/` (skill `homelab-repo`).
- Before destructive actions (deleting data, restoring backups over live data,
  wiping a VM) state what you will do in one line, then do it. The owner
  granted full access; do not ask for confirmation on routine operations.
- Never print secrets or tokens into the chat.
