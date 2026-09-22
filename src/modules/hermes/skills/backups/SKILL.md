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

# Backups (Kopia on vm-107)

Kopia snapshots the whole NAS tree `/srv/nas` daily at 02:00 (keeps 3 latest,
7 daily, 8 weekly, 12 monthly, 2 annual). Every service keeps its persistent
data in `/srv/nas/data/<service>`. Web UI for the owner: https://backup.lsck0.dev

## Databases are dumped, not snapshotted

A file copy of a live database is not a restorable backup, so at 01:30 - before
the snapshot - every VM with a database dumps it through its own engine into
`/srv/nas/data/db-dumps/<vm>/<name>/` (`src/modules/db-backup.nix`): SQLite via
`.backup`, Postgres via `pg_dump`. 14 dumps are kept per database, and the
snapshot then carries them off the VM.

To restore a database, restore the dump file and load it - do **not** restore
the live data directory over a running service:

- Postgres: `zstd -dc <dump>.sql.zst | psql -U postgres` (the dumps are taken
  with `--clean --if-exists`, so they drop and recreate their own objects).
- SQLite: `zstd -d <dump>.sqlite.zst -o <target>.sqlite3` with the service
  stopped, then start it.

This is also the only copy of two things: the Authelia second-factor enrolments
and the whole lldap directory both live on local disk, not on the NAS.

All commands run on vm-107 with `terminal`: `ssh 10.100.0.107 nas-restore ...`

## Restore a service

1. Find the service's data dir name (usually the service name, see
   `ssh 10.100.0.107 ls /srv/nas/data`) and its VM id in `AGENTS.md`.
2. List snapshots: `ssh 10.100.0.107 nas-restore list` -> `id  local-time  files`
   (oldest first). Snapshots run daily at 02:00 local time. Pick the newest
   snapshot taken **before** the breakage the owner described (e.g. "broke
   this morning" -> today's 02:00 is still good; "broke yesterday evening" ->
   yesterday's 02:00). Write down its **id** (or date).
3. Optional safety net: `ssh 10.100.0.107 nas-restore now` snapshots the broken
   state first. Always select the restore by **id or date**: never by age: ages
   count from the newest snapshot and shift after `now`.
4. Stop the VM that writes the data: `vm stop <id>`.
5. Restore in place: `ssh 10.100.0.107 nas-restore service <name> <snapshot-id|YYYY-MM-DD> --yes`
6. Start the VM: `vm start <id>` and check the service (`podman ps`, logs, HTTP).
7. Report which snapshot (id, date/time) was restored, and the id of the
   safety snapshot if you took one.

## Other

- Files in a snapshot: `nas-restore files <snapshot-id|date> data/<name>`
- Restore a subtree elsewhere (no overwrite): `nas-restore restore <snapshot-id|date> <subpath> /srv/nas/public/restore-<date>`
- Snapshot now (before a risky change): `nas-restore now`
- Raw Kopia CLI with the repository connected: `kopia-nas <args>`
