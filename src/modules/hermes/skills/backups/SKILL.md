---
name: backups
description: Restore or inspect NAS backups with Kopia.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Backup, Restore, Kopia]
    related_skills: [homelab-ops]
---

# Backups (Kopia on vm-106)

Kopia snapshots the whole NAS tree `/srv/nas` daily at 02:00 (keeps 3 latest,
7 daily, 8 weekly, 12 monthly, 2 annual). Every service keeps its persistent
data in `/srv/nas/data/<service>`. Web UI for the owner: https://backup.lsck0.dev

All commands run on vm-106 with `terminal`: `ssh 10.100.0.106 nas-restore ...`

## Restore a service

1. Find the service's data dir name (usually the service name, see
   `ssh 10.100.0.106 ls /srv/nas/data`) and its VM id in `AGENTS.md`.
2. List snapshots: `ssh 10.100.0.106 nas-restore list` -> `id  local-time  files`
   (oldest first). Snapshots run daily at 02:00 local time. Pick the newest
   snapshot taken **before** the breakage the owner described (e.g. "broke
   this morning" -> today's 02:00 is still good; "broke yesterday evening" ->
   yesterday's 02:00). Write down its **id** (or date).
3. Optional safety net: `ssh 10.100.0.106 nas-restore now` snapshots the broken
   state first. Always select the restore by **id or date**: never by age: ages
   count from the newest snapshot and shift after `now`.
4. Stop the VM that writes the data: `vm stop <id>`.
5. Restore in place: `ssh 10.100.0.106 nas-restore service <name> <snapshot-id|YYYY-MM-DD> --yes`
6. Start the VM: `vm start <id>` and check the service (`podman ps`, logs, HTTP).
7. Report which snapshot (id, date/time) was restored, and the id of the
   safety snapshot if you took one.

## Other

- Files in a snapshot: `nas-restore files <snapshot-id|date> data/<name>`
- Restore a subtree elsewhere (no overwrite): `nas-restore restore <snapshot-id|date> <subpath> /srv/nas/public/restore-<date>`
- Snapshot now (before a risky change): `nas-restore now`
- Raw Kopia CLI with the repository connected: `kopia-nas <args>`
