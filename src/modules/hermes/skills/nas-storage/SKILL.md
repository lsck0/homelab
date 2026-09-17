---
name: nas-storage
description: NAS shares, disk space, Syncthing and FileBrowser.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, NAS, NFS, SMB, Syncthing]
    related_skills: [homelab-ops]
---

# NAS (vm-108, 10.100.0.108, 750 GB disk)

Layout under `/srv/nas`:
- `data/<service>` persistent data of every service (NFS-mounted by the VMs)
- `media/{movies,tv,anime,music,books,manga,audiobooks,leaving-soon}`
- `torrents` downloads, `documents` (Paperless consume dir), `public`, `syncthing`
- `BACKUPS/kopia` Kopia repository (see `backups`)

## Tasks

- Space: `ssh 10.100.0.108 'df -h /srv/nas; du -sh /srv/nas/* /srv/nas/data/* 2>/dev/null | sort -h | tail -20'`
- Find big files: `ssh 10.100.0.108 'find /srv/nas/media -size +10G -printf "%s %p\n" | sort -n | tail'`
- NFS: `exportfs -v`, clients `ss -tn sport = :2049`. A client VM hangs on I/O
  if the NAS is down (hard mounts) and recovers when it is back.
- SMB shares (guest): public, media, documents, BACKUPS (read-only), homelab.
- Syncthing GUI https://sync.lsck0.dev; API on the VM: `curl -s localhost:8384/rest/system/status -H "X-API-Key: $(xmllint --xpath 'string(//apikey)' /var/lib/syncthing/config.xml)"`.
- FileBrowser https://nas.lsck0.dev (whole tree).
- Share a file publicly: copy into the external share app (see `public-apps`) rather than exposing the NAS.
- Media deletion: prefer the *arr APIs (see `media`) so libraries stay consistent; delete raw files only for orphans.
