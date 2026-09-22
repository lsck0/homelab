# VM inventory. One entry per VM; field reference and defaults in lib.tf.
# Nix config for each VM lives in src/instances/<name>.nix.

locals {
  instances = {
    # internal: 10.100.0.0/24, reached through internal Traefik (Authelia-gated)
    "100" = { # internal reverse proxy: TLS/ACME + Authelia ForwardAuth + on-demand proxy
      enabled = true,
      name    = "100-internal-traefik",
      type    = "internal",
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
    "104" = { # observability: Prometheus + Loki + Tempo + Grafana (Grafana owns alerting)
      enabled = true,
      name    = "104-internal-grafana",
      type    = "internal",
    }
    "105" = { # uptime/status monitoring
      enabled = true,
      name    = "105-internal-uptime-kuma",
      type    = "internal",
    }
    "106" = { # backups: Kopia server + web UI, snapshots the NAS
      enabled = true,
      name    = "106-internal-kopia",
      type    = "internal",
      memory  = 2048,
      disk    = 16,
    }
    "107" = { # endpoint protection: Wazuh manager + indexer + dashboard
      enabled = true,
      name    = "107-internal-wazuh",
      type    = "internal",
      memory  = 8192,
      cores   = 4,
      disk    = 60,
    }

    "108" = { # storage: NFS + SMB + Syncthing + FileBrowser
      enabled    = true,
      name       = "108-internal-nas",
      type       = "internal",
      boot_order = 2,
      memory     = 2048,
      disk       = 750,
    }
    "109" = { # Nix binary cache (substituter)
      enabled = true,
      name    = "109-internal-attic",
      type    = "internal",
      disk    = 40,
    }
    "110" = { # shared Rust/C++ compile cache
      enabled = true,
      name    = "110-internal-sccache",
      type    = "internal",
    }

    "111" = { # torrent client (egress via tor-router)
      enabled = true,
      name    = "111-internal-qbittorrent",
      type    = "internal",
    }
    "112" = { # Tor SOCKS gateway for qbittorrent egress
      enabled = true,
      name    = "112-internal-tor-router",
      type    = "internal",
    }

    "113" = { # GPU LLM agent: Hermes (Telegram) + Ollama on the passed-through RTX 2060
      enabled = false,
      name    = "113-internal-hermes",
      type    = "internal",
      memory  = 12288,
      cores   = 8,
      disk    = 60,
      machine = "q35",
      hostpci = ["gpu"],
    }

    "114" = { # git forge (OIDC + SSH)
      enabled = true,
      name    = "114-internal-forgejo",
      type    = "internal",
    }
    "115" = { # CI runner for Forgejo
      enabled = true,
      name    = "115-internal-forgejo-runner",
      type    = "internal",
    }
    "116" = { # CI runners for GitHub repos (ephemeral, one systemd unit per replica)
      # off until the github-runner-token secret is filled: without it every
      # runner unit dies on start and sync.sh exits 1 for the whole lab.
      #   sops set src/secrets.json '["github-runner-token"]' '"ghp_..."'
      enabled = false,
      name    = "116-internal-github-runner",
      type    = "internal",
      memory  = 4096,
      cores   = 4,
      disk    = 40,
    }
    "117" = { # Docker image registry + UI (internal-only)
      enabled = true,
      name    = "117-internal-registry",
      type    = "internal",
    }

    "118" = { # password manager (Bitwarden-compatible)
      enabled = false,
      name    = "118-internal-vaultwarden",
      type    = "internal",
    }
    "119" = { # files / groupware cloud
      enabled = false,
      name    = "119-internal-nextcloud",
      type    = "internal",
    }
    "120" = { # synced calendar feeds (Outlook/StudIP/Proton -> TRMNL)
      enabled = true,
      name    = "120-internal-calendar",
      type    = "internal",
    }
    "121" = { # document management (paperless-ngx)
      enabled = false,
      name    = "121-internal-paperless",
      type    = "internal",
      memory  = 2048,
    }
    "122" = { # AI auto-tagging for paperless
      enabled = false,
      name    = "122-internal-paperless-ai",
      type    = "internal",
      memory  = 2048,
    }
    "123" = { # wiki / knowledge base
      enabled = false,
      name    = "123-internal-wikijs",
      type    = "internal",
    }
    "124" = { # Firefly III personal finance
      enabled = false,
      name    = "124-internal-firefly",
      type    = "internal",
    }

    "125" = { # home automation hub
      enabled = false,
      name    = "125-internal-homeassistant",
      type    = "internal",
    }
    "126" = { # automation agents / scraping
      enabled = false,
      name    = "126-internal-huginn",
      type    = "internal",
    }
    "127" = { # MQTT broker (Home Assistant / IoT)
      enabled = false,
      name    = "127-internal-mosquitto",
      type    = "internal",
    }

    "128" = { # media requests: movies, series, anime (-> Radarr/Sonarr)
      enabled = true,
      name    = "128-internal-jellyseerr",
      type    = "internal",
    }
    "129" = { # indexer manager, syncs indexers into every *arr
      enabled = true,
      name    = "129-internal-prowlarr",
      type    = "internal",
    }
    "130" = { # movie library manager
      enabled = true,
      name    = "130-internal-radarr",
      type    = "internal",
    }
    "131" = { # series + anime library manager
      enabled = true,
      name    = "131-internal-sonarr",
      type    = "internal",
    }
    "132" = { # subtitle downloader for *arr
      enabled = true,
      name    = "132-internal-bazarr",
      type    = "internal",
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
      memory  = 4096,
      cores   = 4,
      disk    = 16,
    }
    "135" = { # audiobooks/podcasts + Bookshelf (ebook manager)
      enabled = true,
      name    = "135-internal-audiobookshelf",
      type    = "internal",
      memory  = 2048,
    }
    "136" = { # music streaming (Subsonic API) + Lidarr (music manager)
      enabled = true,
      name    = "136-internal-navidrome",
      type    = "internal",
      memory  = 2048,
    }
    "137" = { # manga/ebook reader + Suwayomi (manga downloader)
      enabled = true,
      name    = "137-internal-kavita",
      type    = "internal",
      memory  = 2048,
    }

    # external: 10.200.0.0/24 DMZ, public through external Traefik (CrowdSec/WAF)
    "200" = { # public reverse proxy: TLS + CrowdSec + Anubis + WAF + internal relay
      enabled = true,
      name    = "200-external-traefik",
      type    = "external",
    }
    "201" = { # Tailscale control server (VPN mesh)
      enabled = false,
      name    = "201-external-headscale",
      type    = "external",
    }
    "202" = { # non-exit Tor relay
      enabled = false,
      name    = "202-external-tor-relay",
      type    = "external",
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
      enabled = false,
      name    = "205-external-shlink",
      type    = "external",
    }
    "206" = { # encrypted pastebin
      enabled = false,
      name    = "206-external-privatebin",
      type    = "external",
    }
    "207" = { # public file sharing
      enabled = false,
      name    = "207-external-share",
      type    = "external",
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
      enabled = false,
      name    = "209-external-hello",
      type    = "external",
      memory  = 2048,
    }

    # router
    "300" = { # gateway: NAT + nftables firewall + Kea DHCP + CoreDNS/blocky + WireGuard + DDNS
      enabled    = true,
      name       = "luca-router",
      type       = "router",
      boot_order = 1,
    }
  }
}
