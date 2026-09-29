---
name: jellyseerr
description: Jellyseerr media requests (request, list, approve, decline).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Media, Jellyseerr, Requests]
    related_skills: [media, jellyfin]
---

# Jellyseerr (vm-128, http://10.100.0.128)

The owner's request front-end for the media stack: it asks for a film or show,
Jellyseerr sends it to Radarr/Sonarr (the `media` skill), and Jellyfin serves it.
Use this to request on the owner's behalf and to clear the approval queue. For
adding media straight to Radarr/Sonarr without a request, use the `media` skill.

Token `lab-token jellyseerr-key`, header `X-Api-Key: <token>`. Base `/api/v1`.
Published on port 80, so call `http://10.100.0.128/api/v1/...`. It is onDemand:
`vm start 128` first, then wait for it to answer.

- Find something: `GET /api/v1/search?query=<text>` — results carry `id` (TMDB id)
  and `mediaType` (`movie` or `tv`).
- Request a film: `POST /api/v1/request {"mediaType":"movie","mediaId":<tmdbId>}`.
- Request a show: `POST /api/v1/request {"mediaType":"tv","mediaId":<tmdbId>,"seasons":"all"}`
  (or a list of season numbers instead of `"all"`).
- Pending queue: `GET /api/v1/request?filter=pending`. Each entry has an `id`.
- Approve / decline: `POST /api/v1/request/<id>/approve` or `.../decline`.
- Request status of a title: `GET /api/v1/media` or the `mediaInfo` on the search result.

Owner requests auto-approve (they are the admin), so a plain request is usually
enough; only touch approve/decline when clearing someone else's pending items.
