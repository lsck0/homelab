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
    "101" = { # SSO: authelia (OIDC + ForwardAuth) and lldap, its identity store
      enabled = true,
      name    = "101-internal-authelia",
      type    = "internal",
      memory  = 1024,
    }

    "103" = { # dashboard / service landing page
      enabled = true,
      kind    = "lxc",
      name    = "103-internal-homepage",
      type    = "internal",
      # nfs mounts need a privileged container
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "104" = { # e-ink terminal feeds: calendar, homelab stats, arXiv
      enabled    = true,
      kind       = "lxc",
      name       = "104-internal-terminal",
      type       = "internal",
      privileged = true,
      features   = "nesting=1,mount=nfs",
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

    "109" = { # storage: NFS + SMB + Syncthing + FileBrowser, Kopia backups of it
      enabled    = true,
      name       = "109-internal-nas",
      type       = "internal",
      boot_order = 2,
      # kopia snapshots the whole nas, measured 624 MiB
      memory  = 3072,
      balloon = 2048,
      # nvme root: state, backups, documents
      disk = 750,
      # bulk storage on the 2 tb hdd
      extra_disks = var.bulk_datastore == "" ? [] : [{ size = 1800, datastore = var.bulk_datastore }],
    }
    "110" = { # build caches: attic (nix) + sccache redis
      enabled = true,
      kind    = "lxc",
      name    = "110-internal-cache",
      type    = "internal",
      # redis caps itself at 768mb
      memory = 1024,
      disk   = 40,
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

    "115" = { # git forge (OIDC + SSH) and its CI runner
      enabled = true,
      name    = "115-internal-forgejo",
      type    = "internal",
      memory  = 2048,
      # runner job images
      disk = 24,
    }
    "117" = { # ci runners for github repos (ephemeral)
      # token is the gh cli's gho_ token
      # ci off for now
      enabled = false,
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

    "121" = { # document management (paperless-ngx) and paperless-ai auto-tagging
      enabled = true,
      name    = "121-internal-paperless",
      type    = "internal",
      # ocr plus the paperless-ai node process
      memory = 3072,
      # ran at 98% of a 2048 floor
      balloon = 2560,
      # paperless-ai image alone is 8.3 GiB
      disk = 24,
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
      # not in use yet
      enabled = false,
      name    = "126-internal-huginn",
      type    = "internal",
      # rails plus postgres, measured 1003 MiB
      memory  = 2048,
      balloon = 1536,
      # image plus postgres left 396 MiB free on 8 GiB
      disk = 16,
    }

    "128" = { # media requests: movies, series, anime (-> Radarr/Sonarr)
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "128-internal-jellyseerr",
      type       = "internal",
      memory     = 1024,
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "130" = { # *arr stack: prowlarr + flaresolverr, radarr, sonarr, lidarr, bazarr, recyclarr
      enabled = true,
      name    = "130-internal-arr",
      type    = "internal",
      # four .net apps thrashed at a 512 floor each, flaresolverr's chromium at 1024
      memory  = 4096,
      balloon = 3072,
      disk    = 16,
    }
    "134" = { # media streaming + Janitorr (deletes media unwatched for months)
      enabled = true,
      name    = "134-internal-jellyfin",
      type    = "internal",
      # vfio pins all ram, so no balloon
      memory  = 3072,
      balloon = 0,
      cores   = 4,
      # ollama model 4.4G beside jellyfin
      disk    = 24,
      machine = "q35",
      hostpci = ["gpu"],
    }
    "136" = { # music streaming (Subsonic API)
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "136-internal-navidrome",
      type       = "internal",
      privileged = true,
      features   = "nesting=1,mount=nfs",
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
      kind    = "lxc",
      name    = "203-external-ntfy",
      type    = "external",
    }
    "204" = { # privacy metasearch
      enabled = "onDemand",
      kind    = "lxc",
      name    = "204-external-searxng",
      type    = "external",
      # podman needs keyctl; dmz, so never privileged
      features = "nesting=1,keyctl=1",
    }
    "206" = { # encrypted pastebin
      enabled = "onDemand",
      name    = "206-external-privatebin",
      type    = "external",
    }
    "207" = { # public file sharing
      enabled = "onDemand",
      name    = "207-external-share",
      type    = "external",
      memory  = 1024,
    }
    "208" = { # Minecraft server; lazymc sleeps/wakes the server per real player logins
      # always on; lazymc stops the jvm after 30m of no players. no ballooning: a growing
      # 6g heap in a ballooned-down guest gets oom-killed, so give it a fixed 8g and let
      # the jvm's 6g heap sit resident (2g headroom for the os and jvm off-heap).
      enabled = true,
      name    = "208-external-minecraft",
      type    = "external",
      memory  = 8192,
      balloon = 8192,
      cores   = 4,
      disk    = 16,
    }
    "209" = { # app host: Docker Swarm stacks deployed by CI (Forgejo + GitHub)
      enabled = "onDemand",
      kind    = "lxc",
      name    = "209-external-hello",
      type    = "external",
      # dockerd needs keyctl; dmz, so never privileged
      features = "nesting=1,keyctl=1",
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
