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
| 25565 | 25565 | 10.200.0.200:25565 | Minecraft (TCP passthrough) |
| 51820/udp | 51820/udp | Router | WireGuard VPN |

### VM Layout

| VM  | IP           | Role                    |
|-----|--------------|-------------------------|
| 100 | 10.100.0.100 | Internal Traefik + CrowdSec |
| 101 | 10.100.0.101 | Authentik SSO           |
| 102 | 10.100.0.102 | Homepage dashboard      |
| 103 | 10.100.0.103 | Uptime Kuma             |
| 104 | 10.100.0.104 | Grafana + Prometheus    |
| 105 | 10.100.0.105 | Forgejo (Git)           |
| 106 | 10.100.0.106 | Forgejo Runner (CI)     |
| 107 | 10.100.0.107 | sccache (Redis)         |
| 108 | 10.100.0.108 | Container Registry      |
| 109 | 10.100.0.109 | Taskchampion sync       |
| 110 | 10.100.0.110 | Vaultwarden             |
| 111 | 10.100.0.111 | NAS (NFS + Samba, 100GB)|
| 112 | 10.100.0.112 | Nextcloud               |
| 113 | 10.100.0.113 | qBittorrent             |
| 114 | 10.100.0.114 | Prowlarr                |
| 115 | 10.100.0.115 | Sonarr                  |
| 116 | 10.100.0.116 | Radarr                  |
| 117 | 10.100.0.117 | Jellyfin                |
| 118 | 10.100.0.118 | Audiobookshelf          |
| 119 | 10.100.0.119 | Paperless-ngx           |
| 120 | 10.100.0.120 | Wiki.js                 |
| 121 | 10.100.0.121 | Huginn                  |
| 122 | 10.100.0.122 | Home Assistant          |
| 123 | 10.100.0.123 | Navidrome (music)       |
| 124 | 10.100.0.124 | Kavita (manga/comics)   |
| 200 | 10.200.0.200 | External Traefik + CrowdSec |
| 201 | 10.200.0.201 | Headscale VPN           |
| 202 | 10.200.0.202 | Shlink (URL shortener)  |
| 203 | 10.200.0.203 | PrivateBin              |
| 204 | 10.200.0.204 | Pingvin Share           |
| 205 | 10.200.0.205 | Minecraft               |
| 300 | 192.168.178.29 | NixOS Router          |

Default VM: 2 cores, 2 GB RAM, 8 GB disk. Exceptions: Authentik (4 GB RAM), Minecraft (4 GB RAM, 6 cores), NAS (100 GB disk).

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
