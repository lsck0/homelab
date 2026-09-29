---
name: bazarr
description: Bazarr subtitles for the media stack (list wanted, search, download).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Media, Bazarr, Subtitles]
    related_skills: [media, downloads]
---

# Bazarr (vm-130, http://10.100.0.130:6767)

Subtitles for the films and shows Radarr/Sonarr manage. Use it when the owner
says a title has no subtitles or the wrong language. Bazarr pulls from the
providers and languages configured by `arr-wire.sh`; this skill drives it, it
does not reconfigure it.

Token `lab-token bazarr-key`, header `X-API-KEY: <token>`. Base
`http://10.100.0.130:6767/api`. Runs on vm-130 with the *arr apps.

Confirmed endpoints (used by `arr-wire.sh`):
- Health/config: `GET /api/system/settings`, `GET /api/system/status`.
- Restart: `POST /api/system?action=restart`.

Bazarr's action API is version-specific (this is `v1.6.1-ls364`), so before
acting, confirm the exact route and body against the running instance rather than
assuming. The stable shape:
- Missing subtitles: `GET /api/movies/wanted` and `GET /api/episodes/wanted`.
- Library rows: `GET /api/movies` (has `radarrId`), `GET /api/episodes?seriesid=<id>`.
- Trigger a search: a `PATCH` to `/api/movies` / `/api/episodes` with the item id
  and an action such as `search`. Read `GET /api/` (the OpenAPI index Bazarr
  serves) or the row you got back to get the exact field names for this version,
  then issue the call.

If a route 404s or the body is rejected, say what you tried; do not guess
repeatedly. The reliable fallback is to open Bazarr in the browser behind
`bazarr.lsck0.dev` and tell the owner which title still lacks subtitles.
