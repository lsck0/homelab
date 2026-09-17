---
name: downloads
description: qBittorrent, Tor egress and Prowlarr indexers.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, qBittorrent, Prowlarr, Tor]
    related_skills: [homelab-ops, media]
---

# Downloads

## qBittorrent (vm-111, http://10.100.0.111/api/v2, no login from this VM)

- Torrents: `curl -s http://10.100.0.111/api/v2/torrents/info | jq '.[] | {name, state, progress, dlspeed, category}'`
- Pause/resume: `POST /torrents/stop|start` form `hashes=<h>|all` (older: pause/resume).
- Delete: `POST /torrents/delete` form `hashes=<h>&deleteFiles=true`: only for torrents
  the *arrs no longer track; otherwise remove via Sonarr/Radarr queue so they do not re-grab.
- Speed limits: `POST /transfer/setDownloadLimit limit=<bytes/s>`.
- Save path `/data/torrents`, category per *arr.
- All peer traffic goes through Tor (SOCKS on vm-112). Slow swarms are expected.

## Tor router (vm-112)

- Health: `ssh 10.100.0.112 'systemctl status tor; curl -s --socks5-hostname 10.100.0.112:9050 https://check.torproject.org/api/ip'`.

## Prowlarr (vm-128, http://10.100.0.128/api/v1, key `prowlarr-key`)

- Indexers: `GET /indexer`; test all `POST /indexer/testall`.
- Add a public indexer: take the entry from `GET /indexer/schema` whose `definitionName`
  matches, set `enable: true`, `appProfileId: 1`, `POST /indexer`. Private trackers need
  the owner's credentials in the fields.
- Manual search across indexers: `GET /search?query=<q>&type=search`.
- Apps (sync to Radarr/Sonarr/Lidarr/Bookshelf): `GET /applications`; force sync `POST /command {"name":"ApplicationIndexerSync"}`.
- Wiring is maintained by `arr-wire` on vm-132 (`ssh 10.100.0.132 'systemctl start arr-wire; journalctl -u arr-wire -n 40'`).
