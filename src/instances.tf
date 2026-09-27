# vm inventory

locals {
  instances = {
    # internal: 10.100.0.0/24 behind internal traefik (authelia)
    "100" = { # internal reverse proxy: tls, forwardauth, on-demand wake
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
    "105" = { # observability: prometheus, loki, tempo, grafana
      enabled = true,
      name    = "105-internal-grafana",
      type    = "internal",
      # four services, prometheus keeps 30d
      memory = 3072,
      # explicit floor: tsdb head and loki chunks are working memory
      balloon = 2048,
    }
    "107" = { # backups: Kopia server + web UI, snapshots the NAS
      enabled = true,
      name    = "107-internal-kopia",
      type    = "internal",
      # snapshots the whole nas, measured 624 MiB
      memory = 1024,
      disk   = 16,
    }

    "109" = { # storage: NFS + SMB + Syncthing + FileBrowser
      enabled    = true,
      name       = "109-internal-nas",
      type       = "internal",
      boot_order = 2,
      memory     = 2048,
      balloon    = 2048,
      # nvme root: state, backups, documents
      disk = 750,
      # bulk storage on the 2 tb hdd
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

    "114" = { # Hermes: Telegram agent, cloud models only, root on the lab
      enabled = true,
      name    = "114-internal-hermes",
      type    = "internal",
      memory  = 1536,
      disk    = 60,
      machine = "q35",
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
    "117" = { # ci runners for github repos (ephemeral)
      # token is the gh cli's gho_ token
      enabled = true,
      name    = "117-internal-github-runner",
      type    = "internal",
      # four .net listeners plus docker
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
      # ocr plus its own postgres
      memory  = 2048,
      balloon = 1536,
    }
    "122" = { # AI auto-tagging for paperless
      enabled = true,
      name    = "122-internal-paperless-ai",
      type    = "internal",
      # large model image, 8 GiB was 80% full at rest
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
      # large python process, squeezed it stalls
      memory  = 2048,
      balloon = 1536,
      # image alone does not fit in 8 GiB
      disk = 16,
    }
    "126" = { # automation agents / scraping
      enabled = true,
      name    = "126-internal-huginn",
      type    = "internal",
      # rails plus postgres, measured 1003 MiB
      memory  = 2048,
      balloon = 1536,
      # image plus postgres left 396 MiB free on 8 GiB
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
      # flaresolverr's chromium thrashed at a 512 floor
      memory  = 1536,
      balloon = 1024,
    }
    "130" = { # movie library manager
      enabled = true,
      name    = "130-internal-radarr",
      type    = "internal",
      # .net thrashed at a 512 floor
      memory  = 1024,
      balloon = 1024,
    }
    "131" = { # series + anime library manager
      enabled = true,
      name    = "131-internal-sonarr",
      type    = "internal",
      # .net thrashed at a 512 floor
      memory  = 1024,
      balloon = 1024,
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
      # no balloon: squeezed to 1 GiB it was OOM-killed mid-stream
      memory  = 3072,
      balloon = 3072,
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
      # internal, not dmz: it controls mesh membership
      enabled = true,
      name    = "138-internal-headscale",
      type    = "internal",
    }

    # external: 10.200.0.0/24 dmz behind external traefik (crowdsec/waf)
    "200" = { # public reverse proxy: tls, crowdsec, anubis, waf
      enabled = true,
      name    = "200-external-traefik",
      type    = "external",
      # crowdsec oom-killed at 1024
      memory  = 2048,
      balloon = 1536,
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
      # vanilla; jvm commits its heap at start, 2048 died
      memory  = 4096,
      balloon = 3072,
      cores   = 4,
      disk    = 16,
    }
    "209" = { # app host: Docker Swarm stacks deployed by CI (Forgejo + GitHub)
      enabled = true,
      name    = "209-external-hello",
      type    = "external",
    }

    # router
    "300" = { # gateway: nat, firewall, dhcp, dns, wireguard, ddns
      enabled    = true,
      name       = "luca-router",
      type       = "router",
      memory     = 1024,
      balloon    = 1024,
      boot_order = 1,
    }
  }
}
