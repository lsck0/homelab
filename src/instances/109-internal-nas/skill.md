---
name: nas
description: NAS shares, disk space, Syncthing and FileBrowser.
version: 1.1.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, NAS, NFS, SMB, Syncthing]
    related_skills: [homelab-ops]
---

# NAS (vm-109, 10.100.0.109, 750 GB disk)

Layout under `/srv/nas`:
- `data/<service>` persistent data of every service (NFS-mounted by the VMs)
- `bulk/` the 2 TB hdd, not backed up: `bulk/media/{movies,tv,anime,music,leaving-soon}`, `bulk/torrents` finished downloads;
  media and torrents share a 750 GiB ext4 project quota (`mediaQuotaGiB` in `src/instances/109-internal-nas/main.nix`).
  Incomplete torrents live on vm-112's own 150 GiB disk, not on the NAS.
- `documents` (`inbox/` is the Paperless consume dir, `archive/` a read-only view of all Paperless documents), `public`, `syncthing`
- `BACKUPS/kopia` Kopia repository (see `backups`)

## Tasks

- Space: `ssh 10.100.0.109 'df -h /srv/nas; du -sh /srv/nas/* /srv/nas/data/* 2>/dev/null | sort -h | tail -20'`
- Find big files: `ssh 10.100.0.109 'find /srv/nas/bulk/media -size +10G -printf "%s %p\n" | sort -n | tail'`
- NFS: `exportfs -v`, clients `ss -tn sport = :2049`. A client VM hangs on I/O
  if the NAS is down (hard mounts) and recovers when it is back.
- SMB shares (guest): public, media, documents, syncthing, BACKUPS (read-only). There is no share of the whole tree: the
  service state under `data/` is NFS only, each guest mounting just its own shares.
- `data/tokens/vm-<id>` and `data/db-dumps/<vm>` belong to root (0755 and 0700): only the producing guest's root
  writes them. Never loosen their modes; vm-109's tmpfiles rules set them back on every boot.
- Syncthing GUI https://sync.lsck0.dev; API on the VM: `curl -s localhost:8384/rest/system/status -H "X-API-Key: $(xmllint --xpath 'string(//apikey)' /var/lib/syncthing/config.xml)"`.
- FileBrowser https://nas.lsck0.dev (whole tree).
- Share a file publicly: copy into the external share app (see `public-apps`) rather than exposing the NAS.
- Media deletion: prefer the *arr APIs (see `media`) so libraries stay consistent; delete raw files only for orphans.
