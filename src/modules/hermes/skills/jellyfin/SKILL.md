---
name: jellyfin
description: Jellyfin users, libraries, sessions and cleanup.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Jellyfin, Media]
    related_skills: [homelab-ops, media]
---

# Jellyfin (vm-133, http://10.100.0.133, https://jellyfin.lsck0.dev)

Header `Authorization: MediaBrowser Token="$(lab-token jellyfin-key)"` (Jellyfin 12 rejects X-Emby-Token and api_key).

- Libraries: `GET /Library/VirtualFolders`; rescan all `POST /Library/Refresh`.
  Movies `/data/media/movies`, Shows `/data/media/tv`, Anime `/data/media/anime`.
- Search: `GET /Items?searchTerm=<t>&Recursive=true&IncludeItemTypes=Movie,Series`.
- Who is watching: `GET /Sessions?activeWithinSeconds=600`.
- Users: `GET /Users`; create `POST /Users/New {"Name":..,"Password":..}`;
  password `POST /Users/<id>/Password {"NewPw":..}` (admin reset: `{"ResetPassword":true}` first).
- Play history (used for cleanup): janitorr-stats on the same VM, `http://10.100.0.133:8081`.
- Admin password (for UI login): `lab-token jellyfin-admin-pass`.

## Janitorr (automatic cleanup)

- Rules: movies/seasons not watched (or, never watched, not grabbed) for 120
  days are deleted; sooner when free space < 25 %. "Leaving Soon" collections
  show them 14 days before.
- Keep something forever: add tag `janitorr_keep` in Radarr/Sonarr
  (`POST /api/v3/tag {"label":"janitorr_keep"}`, then add the tag id to the movie/series and `PUT` it).
- Logs: `ssh 10.100.0.133 'podman logs --tail 100 janitorr'`.
- Config (rendered): `/var/lib/janitorr/application.yml`; thresholds are Nix (`133-internal-jellyfin.nix`).
