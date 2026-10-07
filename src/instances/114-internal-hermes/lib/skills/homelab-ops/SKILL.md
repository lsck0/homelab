---
name: homelab-ops
description: Inspect the homelab VMs and services; hand changes to the owner.
version: 2.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Proxmox, NixOS, SSH, Operations]
    related_skills: [minecraft, backups, media, bills]
---

# Homelab operations

You are read-only on the lab's hosts. Read `AGENTS.md` in your working directory
first: it has the VM inventory (addresses, power) and wins over any address or
state a skill mentions.

## Tools (run with `terminal`)

- `ssh <ip> <command>`: the read-only `observer` account on any VM (10.100.0.<id> internal,
  10.200.0.<id> external, 10.250.0.<id> apps zone) and on the router (10.100.0.1); it runs
  `systemctl status|show|cat|is-active|is-failed|is-enabled|list-units|list-timers|list-unit-files`,
  `journalctl`, `df`, `free` and `uptime`, and refuses everything else.
- Root commands in the skills (restarts, `podman`, restores, the Proxmox host's `qm`, `pct`, `pvesh`, starting
  an idle VM with `vm start <id>`) are the owner's: send the exact commands and what they change.
- `lab-token <name>`: API keys the VMs export, e.g. `radarr-key`, `sonarr-key`, `lidarr-key`, `prowlarr-key`,
  `jellyfin-key-hermes`, `jellyseerr-key`, `bazarr-key`, `paperless-key`, `firefly-token`, `forgejo-hermes`
  (`lab-token` alone lists them).
- `lab-notify`: a push to the owner over ntfy (skill `ntfy`).

## Services

- Containers run under podman as `podman-<name>` units: `ssh <ip> systemctl status podman-<name>`,
  `ssh <ip> journalctl -u podman-<name> -n 100`.
- Logs of every VM are in Loki: `curl -sG http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-208"}' --data-urlencode limit=50`
  or `ssh <ip> journalctl -u <unit> -n 100`.
- Alerts go to ntfy (topic `homelab-alerts`), and to Telegram for rules labeled `notify=telegram`, grouped by
  category (skill `grafana`); metrics in Prometheus on 10.100.0.105:9090.
- Setup units configure an app after it starts and retry every 30 s until they succeed (`<app>-setup`,
  `*-token`); a unit stuck in `activating (auto-restart)` names the reason in its journal.

## Rules

- NixOS config is declarative (git repo `homelab`, deployed by `sync.sh` from
  the owner's PC; you never deploy). Runtime state (app settings through their
  APIs, files on the NAS) persists. When a change must be permanent in Nix, open
  a pull request for the file under `src/` (skill `homelab-repo`).
- What changes a VM goes to the owner as exact commands, destructive ones
  (deleting data, restoring backups over live data, wiping a VM) with what is
  lost; a change that belongs in Nix goes into a pull request.
- Never print secrets or tokens into the chat.
