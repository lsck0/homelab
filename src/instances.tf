# VM inventory.

locals {
  instances = {
    # internal: 10.100.0.0/24, reached through internal Traefik (Authelia-gated)
    "100" = { # internal reverse proxy: TLS/ACME + Authelia ForwardAuth + on-demand proxy
      enabled = true,
      name    = "100-internal-traefik",
      type    = "internal",
      memory  = 1024,
    }
    "101" = { # SSO: OIDC provider + ForwardAuth (backed by lldap)
      enabled = true,
      name    = "101-internal-authelia",
      type    = "internal",
    }
    "102" = { # LDAP identity store + admin dashboard (users/groups)
      enabled = true,
      name    = "102-internal-lldap",
      type    = "internal",
    }

    "103" = { # dashboard / service landing page
      enabled = true,
      name    = "103-internal-homepage",
      type    = "internal",
    }
    "104" = { # e-ink terminal feeds: calendar, homelab stats, arXiv
      enabled = true,
      name    = "104-internal-terminal",
      type    = "internal",
    }
    "105" = { # observability: Prometheus + Loki + Tempo + Grafana (Grafana owns alerting)
      enabled = true,
      name    = "105-internal-grafana",
      type    = "internal",
      # Four services, not one: Prometheus (30d retention), Loki, Tempo, Grafana
      memory = 3072,
      # An explicit floor rather than half: the TSDB head and Loki's chunks are working memory
      balloon = 2048,
    }
    "107" = { # backups: Kopia server + web UI, snapshots the NAS
      enabled = true,
      name    = "107-internal-kopia",
      type    = "internal",
      # snapshots the whole NAS tree; measured 624 MiB and does real IO.
      memory = 1024,
      disk   = 16,
    }

    "109" = { # storage: NFS + SMB + Syncthing + FileBrowser
      enabled    = true,
      name       = "109-internal-nas",
      type       = "internal",
      boot_order = 2,
      memory     = 2048,
      # root disk on the NVMe pool: service state, backups and documents - the things
      disk = 750,
      # Bulk storage on the 2 TB spinning disk.
      extra_disks = var.bulk_datastore == "" ? [] : [{ size = 1800, datastore = var.bulk_datastore }],
    }
    "110" = { # Nix binary cache (substituter)
      enabled = true,
      name    = "110-internal-attic",
      type    = "internal",
      disk    = 40,
    }
    "111" = { # shared Rust/C++ compile cache
      enabled = true,
      name    = "111-internal-sccache",
      type    = "internal",
    }

    "112" = { # torrent client (egress via tor-router)
      enabled = true,
      name    = "112-internal-qbittorrent",
      type    = "internal",
      memory  = 1024,
    }

    "114" = { # Hermes: the Telegram agent with root on the lab
      enabled = true,
      name    = "114-internal-hermes",
      type    = "internal",
      # VFIO pins the guest's whole RAM up front, so this VM costs its full `memory` the moment
      memory  = 5120,
      balloon = 0,
      cores   = 4,
      disk    = 60,
      machine = "q35",
      hostpci = ["gpu"],
    }

    "115" = { # git forge (OIDC + SSH)
      enabled = true,
      name    = "115-internal-forgejo",
      type    = "internal",
      memory  = 1024,
    }
    "116" = { # CI runner for Forgejo
      enabled = true,
      name    = "116-internal-forgejo-runner",
      type    = "internal",
      memory  = 1024,
    }
    "117" = { # CI runners for GitHub repos (ephemeral, one systemd unit per replica)
      # github-runner-token is the gh CLI's own gho_ token; the runner module only detects
      enabled = true,
      name    = "117-internal-github-runner",
      type    = "internal",
      # four .NET listeners plus docker.
      memory  = 4096,
      balloon = 2048,
      cores   = 4,
      disk    = 40,
    }
    "118" = { # Docker image registry + UI (internal-only)
      enabled = true,
      name    = "118-internal-registry",
      type    = "internal",
    }

    "121" = { # document management (paperless-ngx)
      enabled = true,
      name    = "121-internal-paperless",
      type    = "internal",
      # OCR plus its own Postgres.
      memory  = 2048,
      balloon = 1536,
    }
    "122" = { # AI auto-tagging for paperless
      enabled = true,
      name    = "122-internal-paperless-ai",
      type    = "internal",
      # paperless-ai pulls a large model image; 8 GiB was 80% full at rest.
      disk = 16,
    }
    "124" = { # Firefly III personal finance
      enabled = true,
      name    = "124-internal-firefly",
      type    = "internal",
      memory  = 1024,
    }

    "125" = { # home automation hub
      enabled = true,
      name    = "125-internal-homeassistant",
      type    = "internal",
      # Home Assistant is a large Python process with dozens of integrations; squeezed toward
      memory  = 2048,
      balloon = 1536,
      # Home Assistant's image alone does not fit in 8 GiB: the pull failed with
      disk = 16,
    }
    "126" = { # automation agents / scraping
      enabled = true,
      name    = "126-internal-huginn",
      type    = "internal",
      # Rails plus its own Postgres; measured at 1003 MiB, i.e. at the old ceiling.
      memory  = 2048,
      balloon = 1536,
      # the huginn image plus its Postgres left 396 MiB free on an 8 GiB disk.
      disk = 16,
    }
    "127" = { # MQTT broker (Home Assistant / IoT)
      enabled = true,
      name    = "127-internal-mosquitto",
      type    = "internal",
    }

    "128" = { # media requests: movies, series, anime (-> Radarr/Sonarr)
      enabled = true,
      name    = "128-internal-jellyseerr",
      type    = "internal",
      memory  = 1024,
    }
    "129" = { # indexer manager, syncs indexers into every *arr
      enabled = true,
      name    = "129-internal-prowlarr",
      type    = "internal",
      memory  = 1024,
    }
    "130" = { # movie library manager
      enabled = true,
      name    = "130-internal-radarr",
      type    = "internal",
      memory  = 1024,
    }
    "131" = { # series + anime library manager
      enabled = true,
      name    = "131-internal-sonarr",
      type    = "internal",
      memory  = 1024,
    }
    "132" = { # subtitle downloader for *arr
      enabled = true,
      name    = "132-internal-bazarr",
      type    = "internal",
      memory  = 1024,
    }
    "133" = { # TRaSH-guide sync + *arr/qBittorrent/Prowlarr wiring
      enabled = true,
      name    = "133-internal-recyclarr",
      type    = "internal",
    }
    "134" = { # media streaming + Janitorr (deletes media unwatched for months)
      enabled = true,
      name    = "134-internal-jellyfin",
      type    = "internal",
      memory  = 2048,
      cores   = 4,
      disk    = 16,
    }
    "136" = { # music streaming (Subsonic API) + Lidarr (music manager)
      enabled = true,
      name    = "136-internal-navidrome",
      type    = "internal",
      memory  = 1024,
    }
    "138" = { # Tailscale control server (VPN mesh) + Headplane UI
      # Internal, not the DMZ: it decides which machines are on the mesh
      enabled = true,
      name    = "138-internal-headscale",
      type    = "internal",
    }

    # external: 10.200.0.0/24 DMZ, public through external Traefik (CrowdSec/WAF)
    "200" = { # public reverse proxy: TLS + CrowdSec + Anubis + WAF + internal relay
      enabled = true,
      name    = "200-external-traefik",
      type    = "external",
      # Traefik + CrowdSec + AppSec + Anubis + iocaine; OOM-killed crowdsec at 1024
      memory  = 2048,
      balloon = 1536,
    }
    "202" = { # non-exit Tor relay
      enabled = true,
      name    = "202-external-tor-relay",
      type    = "external",
      # A public relay, not a client: it carries other people's circuits
      memory  = 1536,
      balloon = 1024,
    }
    "203" = { # push notifications (alert delivery)
      enabled = true,
      name    = "203-external-ntfy",
      type    = "external",
    }
    "204" = { # privacy metasearch
      enabled = true,
      name    = "204-external-searxng",
      type    = "external",
    }
    "205" = { # URL shortener
      enabled = true,
      name    = "205-external-shlink",
      type    = "external",
    }
    "206" = { # encrypted pastebin
      enabled = true,
      name    = "206-external-privatebin",
      type    = "external",
    }
    "207" = { # public file sharing
      enabled = true,
      name    = "207-external-share",
      type    = "external",
      memory  = 1024,
    }
    "208" = { # Minecraft server, boots when a player connects
      enabled = false,
      name    = "208-external-minecraft",
      type    = "external",
      memory  = 20480,
      cores   = 8,
      disk    = 16,
    }
    "209" = { # app host: Docker Swarm stacks deployed by CI (Forgejo + GitHub)
      enabled = true,
      name    = "209-external-hello",
      type    = "external",
    }

    # router
    "300" = { # gateway: NAT + nftables firewall + Kea DHCP + CoreDNS/blocky + WireGuard + DDNS
      enabled    = true,
      name       = "luca-router",
      type       = "router",
      memory     = 1024,
      boot_order = 1,
    }
  }
}
