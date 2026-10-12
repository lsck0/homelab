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

# Jellyfin (vm-134, http://10.100.0.134, https://jellyfin.lsck0.dev)

Header `Authorization: MediaBrowser Token="$(lab-token jellyfin-key-hermes)"` (Jellyfin 12 rejects X-Emby-Token
and api_key). The key is yours alone: every consumer has its own (`homelab-<consumer>` under `GET /Auth/Keys`).

- Logins: browsers go through Authelia (SSO plugin, members of lldap group `app-jellyfin`; `admins` among them
  get the admin flag). Apps and Jellyseerr log in with Quick Connect: the user opens Jellyfin in a browser,
  Settings, Quick Connect, and enters the code the app shows. There are no Jellyfin passwords to reset; a new
  user is a new lldap account in `app-jellyfin` (skill `identity-sso`).
- Libraries: `GET /Library/VirtualFolders`; rescan all `POST /Library/Refresh`.
  Movies `/data/media/movies`, Shows `/data/media/tv`, Anime `/data/media/anime`.
- Search: `GET /Items?searchTerm=<t>&Recursive=true&IncludeItemTypes=Movie,Series`.
- Who is watching: `GET /Sessions?activeWithinSeconds=600`.
- Users: `GET /Users`.
- Play history (used for cleanup): janitorr-stats on the same VM, localhost only:
  `ssh 10.100.0.134 'curl -s http://127.0.0.1:8081/<path>'`.
- The local admin (setup only): `lab-token jellyfin-admin-pass`. `jellyfin-setup.service` sets everything up and
  reruns with every Jellyfin restart: `ssh 10.100.0.134 journalctl -u jellyfin-setup -n 50`.

## Janitorr (automatic cleanup)

- Rules: movies/seasons not watched (or, never watched, not grabbed) for 120
  days are deleted; sooner when free space < 25 %. "Leaving Soon" collections
  show them 14 days before.
- Keep something forever: add tag `janitorr_keep` in Radarr/Sonarr
  (`POST /api/v3/tag {"label":"janitorr_keep"}`, then add the tag id to the movie/series and `PUT` it).
- Logs: `ssh 10.100.0.134 'podman logs --tail 100 janitorr'`.
- Config (rendered): `/var/lib/janitorr/application.yml`; thresholds are Nix (`src/instances/134-internal-jellyfin/main.nix`).
