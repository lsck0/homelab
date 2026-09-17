---
name: media
description: Get movies, series, anime, music, books and manga.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Media, Sonarr, Radarr, Lidarr, Jellyfin]
    related_skills: [homelab-ops]
---

# Media requests

Everything lands in `/data/media/<kind>` on the NAS and shows up in the
players automatically. Downloads go through qBittorrent (Tor egress), indexers
through Prowlarr. Media nobody watched for ~4 months is deleted by Janitorr
(tag `janitorr_keep` in Radarr/Sonarr to keep something).

| Kind | Manager (API) | Key | Folder | Player |
|---|---|---|---|---|
| Movies | Radarr `http://10.100.0.129/api/v3` | `radarr-key` | `/data/media/movies` | Jellyfin |
| Series | Sonarr `http://10.100.0.130/api/v3` | `sonarr-key` | `/data/media/tv` | Jellyfin |
| Anime | Sonarr, `seriesType: "anime"` | `sonarr-key` | `/data/media/anime` | Jellyfin |
| Music | Lidarr `http://10.100.0.135:8686/api/v1` | `lidarr-key` | `/data/media/music` | Navidrome |
| Ebooks | Bookshelf `http://10.100.0.134:8787/api/v1` (Readarr API) | `bookshelf-key` | `/data/media/books` | Kavita |
| Manga | Suwayomi `http://10.100.0.136:4567/api/graphql` | none | `/data/media/manga` | Kavita |

Send the key as header `X-Api-Key: $(lab-token <key>)`. Use `terminal` with
`curl` + `jq`.

## "Download the new Bleach episode" (anime/series)

1. Is the show in Sonarr? `GET /api/v3/series` and match `title`.
2. If not, look it up: `GET /api/v3/series/lookup?term=Bleach`, take the right
   result (check year/overview), then add it:
   `POST /api/v3/series` with the lookup object plus
   `qualityProfileId` (first of `GET /api/v3/qualityprofile`),
   `rootFolderPath` (`/data/media/anime` for anime, `/data/media/tv` otherwise),
   `seriesType` (`anime` or `standard`), `monitored: true`, `seasonFolder: true`,
   `addOptions: {"monitor": "future", "searchForMissingEpisodes": false}`.
3. Find the newest aired episode: `GET /api/v3/episode?seriesId=<id>`, pick the
   highest `airDateUtc` in the past. Make sure it is monitored
   (`PUT /api/v3/episode/monitor` with `{"episodeIds":[id],"monitored":true}`).
4. Search it: `POST /api/v3/command` `{"name":"EpisodeSearch","episodeIds":[id]}`.
5. Check progress: `GET /api/v3/queue?seriesId=<id>`. Report the episode
   number/title and that it is downloading; if nothing was found, say so.

"The whole show" instead: add with `monitor: "all"` and
`searchForMissingEpisodes: true`.

## Movies

`GET /api/v3/movie/lookup?term=<title>` -> `POST /api/v3/movie` with
`qualityProfileId`, `rootFolderPath: "/data/media/movies"`, `monitored: true`,
`minimumAvailability: "released"`, `addOptions: {"searchForMovie": true}`.

## Music (Lidarr)

`GET /api/v1/artist/lookup?term=<artist>` -> `POST /api/v1/artist` with
`qualityProfileId`, `metadataProfileId` (`GET /api/v1/metadataprofile`),
`rootFolderPath: "/data/media/music"`, `monitored: true`,
`addOptions: {"monitor": "all", "searchForMissingAlbums": true}`.
For one album: `GET /api/v1/album/lookup?term=<album>`, add the artist with
`monitor: "none"`, then monitor that album and `POST /api/v1/command`
`{"name":"AlbumSearch","albumIds":[id]}`.

## Ebooks (Bookshelf)

`GET /api/v1/search?term=<title author>` -> `POST /api/v1/book` (or
`/api/v1/author`) with `qualityProfileId`, `metadataProfileId`,
`rootFolderPath: "/data/media/books"`, `monitored: true`,
`addOptions: {"searchForNewBook": true}`.

## Manga (Suwayomi GraphQL, no auth)

POST JSON `{"query": "..."}` to `http://10.100.0.136:4567/api/graphql`.
1. Sources: `{ sources { nodes { id displayName lang } } }` (sources are
   installed extensions; if none fit, install one:
   `{ extensions(condition:{isInstalled:false}) { nodes { pkgName name lang } } }` then
   `mutation { updateExtension(input:{id:"<pkgName>", patch:{install:true}}) { clientMutationId } }`).
2. Search: `mutation { fetchSourceManga(input:{source:"<id>", type:SEARCH, query:"<title>", page:1}) { mangas { id title } } }`
3. Add to library: `mutation { updateManga(input:{id:<id>, patch:{inLibrary:true}}) { manga { id } } }`
4. Chapters: `mutation { fetchChapters(input:{mangaId:<id>}) { chapters { id name chapterNumber } } }`
5. Download: `mutation { enqueueChapterDownloads(input:{ids:[...]}) { clientMutationId } }`
New chapters of library manga download automatically every 6 hours. If a
query fails, introspect the schema (`{ __schema { mutationType { fields { name } } } }`).

## Status

- What is downloading: Sonarr/Radarr `GET /api/v3/queue`, Lidarr `GET /api/v1/queue`.
- Force a Jellyfin library scan: `curl -X POST -H "Authorization: MediaBrowser Token=\"$(lab-token jellyfin-key)\"" http://10.100.0.133/Library/Refresh`.
