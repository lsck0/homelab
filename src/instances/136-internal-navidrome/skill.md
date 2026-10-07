---
name: navidrome
description: Navidrome music via the Subsonic API (playlists, search, play stats).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Media, Navidrome, Music, Subsonic]
    related_skills: [media]
---

# Navidrome (vm-136, http://10.100.0.136)

The owner's music server. Browse the library, build playlists, and read listening
stats over the Subsonic API. To add new music to the library, use the `media`
skill (Lidarr); this skill acts on what is already there. When AGENTS.md lists
vm-136 as `onDemand`, `vm start 136` first.

Auth is Subsonic token auth, not a bearer header. Every call takes these query
parameters, from the pre-generated token files:

- `u=$(lab-token navidrome-user)` (the admin user)
- `t=$(lab-token navidrome-token)` (subsonic token)
- `s=$(lab-token navidrome-salt)` (subsonic salt)
- `v=1.16.1&c=hermes&f=json`

So the base is:
`http://10.100.0.136/rest/<endpoint>?u=<u>&t=<t>&s=<s>&v=1.16.1&c=hermes&f=json`

Reads (JSON under `.["subsonic-response"]`):
- Search: `search3?query=<text>`: matching artists, albums, songs (each with an `id`).
- Albums: `getAlbumList2?type=newest` (or `recent`, `frequent`, `random`, `alphabeticalByName`).
- One album's tracks: `getAlbum?id=<albumId>`.
- Playlists: `getPlaylists`; one playlist: `getPlaylist?id=<id>`.
- Now playing / stats: `getNowPlaying`, `getStarred2`.

Writes:
- New playlist: `createPlaylist?name=<name>&songId=<id>&songId=<id>...`.
- Change a playlist: `updatePlaylist?playlistId=<id>&songIdToAdd=<id>` / `&songIndexToRemove=<n>`.
- Star / unstar: `star?id=<id>` / `unstar?id=<id>`.
- Set rating: `setRating?id=<id>&rating=<0-5>`.

Navidrome trusts the `Remote-User` header only from Traefik (10.100.0.100), so from
vm-114 always use the Subsonic token parameters above, never a header.
