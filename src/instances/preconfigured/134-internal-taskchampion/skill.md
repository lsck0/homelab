---
name: taskchampion
description: Taskwarrior sync server: the address, its one client, and its state.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Taskwarrior, Sync]
    related_skills: [homelab-ops]
---

# Taskchampion (vm-134, 10.100.0.134, tasks.lsck0.dev)

taskchampion-sync-server, the sync server of Taskwarrior 3, for the owner's desktop and notebook. Reachable from the
house and wireguard only, no internet name. Use `terminal` for all steps.

## What it holds

Only ciphertext: every client encrypts its versions with its `sync.encryption_secret`, which never reaches the lab.
It admits one client id, the dotfiles' secret `taskwarrior-client-id` (here `taskchampion-client-id`), and refuses
every other with 403. Nothing on the server reads a task; questions about tasks go to the owner's machines.

## State and status

- `ssh 10.100.0.134 systemctl status taskchampion-sync-server`; `journalctl -u taskchampion-sync-server -n 50`.
- `curl -s https://tasks.lsck0.dev/` answers `TaskChampion sync server v<version>`.
- The database `/var/lib/taskchampion-sync-server/taskchampion-sync-server.sqlite3` is copied nightly to the nas
  share `data/taskchampion` (`taskchampion-mirror`) and dumped to `data/db-dumps/vm-134`; a restore goes through
  `nas-restore`.
