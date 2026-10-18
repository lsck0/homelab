---
name: nas
description: NAS shares, disk space, Syncthing and FileBrowser.
version: 1.2.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, NAS, NFS, SMB, Syncthing]
    related_skills: [homelab-ops]
---

# NAS (vm-104, 10.100.0.104, 750 GB disk)

Layout under `/srv/nas`:
- `data/<service>` persistent data of every service (NFS-mounted by the VMs)
- `bulk/` the 2 TB hdd, not backed up: `bulk/media/{movies,tv,anime,music,leaving-soon}`, `bulk/torrents` finished downloads;
  media and torrents share a 750 GiB ext4 project quota (`mediaQuotaGiB` in `src/instances/core/104-internal-nas/main.nix`).
  Incomplete torrents live on vm-120's own 150 GiB disk, not on the NAS.
- `documents` (`inbox/` is the Paperless consume dir, `archive/` a read-only view of all Paperless documents), `public`, `syncthing`
- `BACKUPS/kopia` Kopia repository (see `backups`)

## Tasks

- Space: `ssh 10.100.0.104 'df -h /srv/nas; du -sh /srv/nas/* /srv/nas/data/* 2>/dev/null | sort -h | tail -20'`
- Find big files: `ssh 10.100.0.104 'find /srv/nas/bulk/media -size +10G -printf "%s %p\n" | sort -n | tail'`
- NFS: `exportfs -v`, clients `ss -tn sport = :2049`. A client VM hangs on I/O
  if the NAS is down (hard mounts) and recovers when it is back.
- SMB shares, all for the one samba user `luca` (no guest), encrypted, SMB 3.1.1 only: `homelab` (the whole of
  `/srv/nas` as root, `data/` and `BACKUPS/` included), public, media, documents, syncthing, BACKUPS (read-only), the
  last five acting as nobody. The guests mount `data/` over NFS, each just its own shares. Sessions: `smbstatus --brief`.
- `data/tokens/vm-<id>` and `data/db-dumps/<vm>` belong to root (0755 and 0700): only the producing guest's root
  writes them. Never loosen their modes; vm-104's tmpfiles rules set them back on every boot.
- Syncthing GUI https://sync.lsck0.dev; API on the VM: `curl -s localhost:8384/rest/system/status -H "X-API-Key: $(xmllint --xpath 'string(//apikey)' /var/lib/syncthing/config.xml)"`.
- The syncthing folder is also synced both ways with Proton Drive (`/my-files/homelab-offsite/sync`) every hour:
  `systemctl status proton-bisync`, `journalctl -u proton-bisync`. Its one-time baseline (`proton-bisync-resync`) and
  the proton sign-in (`proton-drive-login`) are the owner's (FEATURES.md, Storage, backups and off-site): report, never run them. Files it
  deleted here wait in `/srv/nas/syncthing/proton-bisync-trash/<date>/` for a month.
- FileBrowser https://nas.lsck0.dev (whole tree).
- Share a file publicly: copy into the external share app (see `public-apps`) rather than exposing the NAS.
- Media deletion: prefer the *arr APIs (see `media`) so libraries stay consistent; delete raw files only for orphans.
