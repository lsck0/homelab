# Homelab IaC

Declarative homelab. Proxmox + NixOS, managed entirely through Terraform and Nix flakes.

## Architecture

- **Hypervisor:** Proxmox VE on bare metal
- **Router (vm-300):** NixOS — nftables, NAT, CoreDNS, Kea DHCP, WireGuard
- **OS:** NixOS on every VM (auto-built golden image)
- **Networks:**
  - `10.100.0.0/24` — Internal LAN: all homelab services behind Traefik + Authentik SSO
  - `10.200.0.0/24` — External DMZ: public-facing apps, isolated from internal
  - `10.0.0.0/24` — WireGuard VPN
- **DNS:** CoreDNS on router — `*.internal` → internal Traefik, `*.external` → external Traefik
- **SSO:** Authentik (ForwardAuth on Traefik for most services, native OIDC for Nextcloud/Forgejo)
- **Security:** CrowdSec on both Traefik instances, nftables DMZ isolation
- **Storage:** NAS VM (NFS + Samba) shared across media/document services
- **Monitoring:** Uptime Kuma, Grafana + Prometheus, Homepage dashboard

### Port Forwarding (FritzBox → Router → Services)

| External Port | Router Port | Destination | Service |
|---------------|-------------|-------------|---------|
| 443 | 443 | 10.200.0.200:443 | External Traefik (Cloudflare proxy) |
| 10100 | 10100 | 10.100.0.100:443 | Internal Traefik (direct) |
| 10200 | 10200 | 10.200.0.200:443 | External Traefik (direct) |
| 9001 | 9001 | 10.200.0.209:9001 | Tor relay ORPort |
| 25565 | 25565 | 10.200.0.200:25565 | Minecraft (TCP passthrough) |
| 51820/udp | 51820/udp | Router | WireGuard VPN |

### VM Layout

| VM  | IP           | Role                    |
|-----|--------------|-------------------------|
| 100 | 10.100.0.100 | Internal Traefik + CrowdSec |
| 101 | 10.100.0.101 | Authentik SSO           |
| 102 | 10.100.0.102 | Homepage dashboard      |
| 103 | 10.100.0.103 | Grafana + Prometheus    |
| 104 | 10.100.0.104 | Uptime Kuma             |
| 105 | 10.100.0.105 | NAS (NFS + Samba, 100GB) |
| 106 | 10.100.0.106 | sccache (Redis)         |
| 107 | 10.100.0.107 | Forgejo (Git)           |
| 108 | 10.100.0.108 | Forgejo Runner (CI)     |
| 109 | 10.100.0.109 | Container Registry      |
| 110 | 10.100.0.110 | Taskchampion sync       |
| 111 | 10.100.0.111 | Vaultwarden             |
| 112 | 10.100.0.112 | Nextcloud               |
| 113 | 10.100.0.113 | Paperless-ngx           |
| 114 | 10.100.0.114 | Huginn                  |
| 115 | 10.100.0.115 | Home Assistant          |
| 116 | 10.100.0.116 | Wiki.js                 |
| 117 | 10.100.0.117 | qBittorrent             |
| 118 | 10.100.0.118 | Prowlarr                |
| 119 | 10.100.0.119 | Radarr                  |
| 120 | 10.100.0.120 | Sonarr                  |
| 121 | 10.100.0.121 | Jellyfin                |
| 122 | 10.100.0.122 | Audiobookshelf          |
| 123 | 10.100.0.123 | Navidrome (music)       |
| 124 | 10.100.0.124 | Kavita (manga/comics)   |
| 125 | 10.100.0.125 | Paperless AI (auto-tagging) |
| 126 | 10.100.0.126 | Hermes (Ollama LLM API) |
| 127 | 10.100.0.127 | Tor router (SOCKS5 gateway) |
| 128 | 10.100.0.128 | Authelia SSO (Authentik replacement) |
| 129 | 10.100.0.129 | Calendar aggregator + TRMNL feed |
| 200 | 10.200.0.200 | External Traefik + CrowdSec |
| 201 | 10.200.0.201 | Headscale VPN           |
| 202 | 10.200.0.202 | SearXNG                 |
| 203 | 10.200.0.203 | Shlink (URL shortener)  |
| 204 | 10.200.0.204 | PrivateBin              |
| 205 | 10.200.0.205 | Pingvin Share           |
| 207 | 10.200.0.207 | Minecraft               |
| 208 | 10.200.0.208 | Hello (demo app)        |
| 209 | 10.200.0.209 | Tor relay (non-exit)    |
| 300 | 192.168.178.29 | NixOS Router          |

Default VM: 2 cores, 1 GB RAM, 8 GB disk. Exceptions: Authentik (4 GB RAM), Paperless AI (2 GB RAM), NAS (2 GB RAM, 750 GB disk), Hermes (12 GB RAM, 8 cores, 60 GB disk), Minecraft (20 GB RAM, 8 cores).

### On-Demand VMs

`src/modules/on-demand.nix` lets a VM stay powered off until something asks for
it. A systemd socket on the proxy VM listens in its place; the first connection
is held in the socket queue while an `ExecStartPre` hook starts the VM through
the Proxmox API, then `systemd-socket-proxyd` forwards traffic. When the proxy
has been idle for `idleTimeout` it exits and `ExecStopPost` shuts the VM down.

```nix
homelab.onDemand = {
  enable = true;
  tokenFile = config.sops.secrets.proxmox-api-token.path;
  services.minecraft = {
    vmid = 207; listenPort = 26565;
    target = "10.200.0.207"; targetPort = 25565;
    idleTimeout = "30m";
  };
};
```

Then point the reverse proxy at `127.0.0.1:<listenPort>` instead of the VM.

Two things limit where this is worth using:

- **Anything that polls the VM keeps it awake.** Homepage widgets hit most
  internal services directly by IP every few seconds, and Uptime Kuma checks
  are configured in its own UI rather than in Nix. A VM with a Homepage widget
  or a Kuma monitor will never go idle. Remove those first.
- **Cold starts are slow.** VM boot plus NFS automount plus service start runs
  30 s to several minutes. Browsers wait; Minecraft clients and most API
  clients time out on the first attempt and need a retry.

Requires a Proxmox API token with `VM.PowerMgmt` and `VM.Audit`, stored in
`src/secrets.json` as `proxmox-api-token` in `USER@REALM!TOKENID=SECRET` form.

### Calendar + TRMNL (vm-129)

`src/modules/calendar-sync.py` pulls every configured ICS feed every 15
minutes, merges them into one calendar, and renders a JSON payload for a TRMNL
private plugin. nginx serves both files.

Configure the sources in `src/secrets.json` under `calendar-sources`, one per
line as `NAME|URL`:

```
work|https://outlook.office365.com/owa/calendar/<id>/reachcalendar.ics
uni|https://studip.example.edu/dispatch.php/calendar/export/ical?<token>
proton|https://calendar.proton.me/api/calendar/v1/url/<id>/calendar.ics
```

Each source is a *published* ICS link, so the merged calendar is read-only.
Get them from Outlook (Settings → Calendar → Shared calendars → Publish; many
work tenants disable this), StudIP (Calendar → Export → iCalendar) and Proton
Calendar (Share → Share with anyone). Events keep their source in
`CATEGORIES`, and UIDs are prefixed with the source name so two feeds reusing
a UID do not collide.

Both files live under a directory named after the `calendar-token` secret, and
that unguessable path is the only thing protecting them — the routes carry no
SSO, because the TRMNL cloud cannot log in:

```
https://cal.lsck0.dev/<calendar-token>/merged.ics    subscribe from any client
https://cal.lsck0.dev/<calendar-token>/trmnl.json    TRMNL polling URL
```

`cal.lsck0.dev` is the one internal host relayed through the external Traefik,
so the feed is reachable from the internet without the DMZ gaining access to
the internal network.

For TRMNL: create a private plugin with strategy **Polling**, point it at the
`trmnl.json` URL, and write the Liquid markup against this shape:

```json
{
  "generated_at": "...",
  "events": [{ "source": "uni", "summary": "...", "location": "...",
               "start": "2026-09-21T10:00:00+02:00", "end": "...",
               "all_day": false }],
  "kraken": { "ticker": { "XXBTZEUR": { "last": 65508.3, "change_pct": -3.2 } },
              "balance": { "XXBT": 0.5 } }
}
```

Events are sorted and cover the next 14 days, with recurrences already
expanded. Kraken prices come from the public ticker and need no credentials;
`balance` stays empty until `kraken-api-key` and `kraken-api-secret` are set.

**Anything that can guess the token URL can read your calendar, and your
Kraken balances if you enable them.** Rotate by changing `calendar-token` and
redeploying — the sync job deletes the old directory on its next run.

## Project Structure

```
sync.sh                   deploy everything (terraform + nixos)
scripts/init.sh           one-time bootstrap (proxmox + image + tfvars)
scripts/deinit.sh         reset proxmox for fresh init

src/
  flake.nix               nixos flake (auto-discovers instances)
  secrets.yaml            encrypted sops-nix secrets
  terraform.tfvars.sops.json  encrypted terraform vars

src/instances/            per-VM nix + terraform configs
  main.tf                 VM definitions (all instances)
  {id}-{type}-{name}.nix  NixOS config per VM
  300-router.nix          router (multi-NIC, NAT, DNS, DHCP, VPN)
  dashboards/             grafana dashboard JSON

src/modules/
  vm/main.tf              terraform VM module (proxmox provider)
  docker-stack.nix        docker compose deployment module
```

## Quick Start

### Prerequisites

`nix`, `sops`, `terraform`, `age`, `jq`, `openssl`

### 1. Initialize

```bash
./scripts/init.sh 192.168.178.200
```

### 2. Deploy

```bash
./sync.sh
```

### 3. Home router setup (one-time, manual)

On your FritzBox (or equivalent):
- Set static DHCP lease: `192.168.178.29` for the router VM
- Set DNS server in DHCP settings: `192.168.178.29`
- Port forwards to `192.168.178.29`: 443/tcp, 25565/tcp, 51820/udp

### 4. Cloudflare DNS

Add a wildcard `*` A record pointing to your public IP (proxied).
Add `mc` and `wg` A records (DNS-only, not proxied) for direct connections.

## Adding a New VM

1. Pick an ID: `1XX` for internal, `2XX` for external. IP = `10.{100|200}.0.{ID}`.
2. Add entry to `src/instances/main.tf`
3. Create `src/instances/{ID}-{type}-{name}.nix`
4. Add Traefik route in `100-internal-traefik.nix` or `200-external-traefik.nix`
5. Add to Authentik `protectedApps` in `101-internal-authentik.nix` (if SSO needed)
6. Add to homepage in `102-internal-homepage.nix`
7. Add monitor in `103-internal-uptime-kuma.nix`
8. `git add -A && ./sync.sh`

The flake auto-discovers files matching `{1,2}XX-{internal,external}-*.nix` plus `300-router.nix`.

## Secrets

Encrypted with [sops-nix](https://github.com/Mic92/sops-nix). Edit: `sops src/secrets.yaml`.

## Minecraft Modpacks

The MC server uses `itzg/minecraft-server`. Edit `205-external-minecraft.nix` and uncomment one:

**Server zip** — place zip at `/var/lib/minecraft-modpacks/` on vm-205:
```
GENERIC_PACK = "/modpacks/server-pack.zip";
```

**CurseForge page** — auto-downloads:
```
TYPE = "AUTO_CURSEFORGE";
CF_PAGE_URL = "https://www.curseforge.com/minecraft/modpacks/...";
```

**Pack with its own run script** — extract to `/var/lib/minecraft/`, then:
```
TYPE = "CUSTOM";
CUSTOM_SERVER = "/data/run.sh";
SKIP_SERVER_PROPERTIES = "true";
EXEC_DIRECTLY = "true";
```

This bypasses the itzg launcher entirely and runs the pack's script directly.

## Authentik Password Recovery

```bash
ssh -J root@192.168.178.29 root@10.100.0.101
docker exec -it authentik-server-1 ak create_recovery_key 10 akadmin
```

Open the printed URL from your LAN browser.
