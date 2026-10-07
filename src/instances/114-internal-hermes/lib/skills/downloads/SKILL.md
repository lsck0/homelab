---
name: downloads
description: qBittorrent (VPN egress) and Prowlarr indexers (Tor).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, qBittorrent, Prowlarr, VPN, Tor]
    related_skills: [homelab-ops, media]
---

# Downloads

## qBittorrent (vm-112, `http://10.100.0.112/api/v2`, no login from this VM)

- Torrents: `curl -s http://10.100.0.112/api/v2/torrents/info | jq '.[] | {name, state, progress, dlspeed, category}'`
- Pause/resume: `POST /torrents/stop|start` form `hashes=<h>|all` (older: pause/resume).
- Delete: `POST /torrents/delete` form `hashes=<h>&deleteFiles=true`: only for torrents
  the *arrs no longer track; otherwise remove via Sonarr/Radarr queue so they do not re-grab.
- Speed limits: `POST /transfer/setDownloadLimit limit=<bytes/s>`.
- Save path `/data/torrents`, category per *arr.
- Peer traffic leaves through the router's ProtonVPN WireGuard exit (`wg-egress`), with a killswitch: no tunnel,
  no peers. The listen port is the one ProtonVPN leases, set by the router's `protonvpn-port` timer. Slow swarms
  are usually few seeders, not the tunnel. Tunnel health: `ssh 10.100.0.1 'wg show wg-egress; journalctl -u protonvpn-port -n 20'`.

## Prowlarr (vm-130, `http://10.100.0.130:9696/api/v1`, key `prowlarr-key`)

- Indexer searches go through the router's Tor SOCKS port, one circuit per destination; flaresolverr beside it
  solves Cloudflare pages. Tor health: `ssh 10.100.0.1 'systemctl status tor'`.
- Indexers: `GET /indexer`; test all `POST /indexer/testall`.
- Add a public indexer: take the entry from `GET /indexer/schema` whose `definitionName`
  matches, set `enable: true`, `appProfileId: 1`, `POST /indexer`. Private trackers need
  the owner's credentials in the fields.
- Manual search across indexers: `GET /search?query=<q>&type=search`.
- Apps (sync to Radarr/Sonarr/Lidarr): `GET /applications`; force sync `POST /command {"name":"ApplicationIndexerSync"}`.
- Wiring is maintained by `arr-wire` on vm-130 (`ssh 10.100.0.130 'systemctl start arr-wire; journalctl -u arr-wire -n 40'`).
