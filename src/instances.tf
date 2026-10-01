# vm inventory

locals {
  instances = {
    # internal: 10.100.0.0/24 behind internal traefik (authelia)
    "100" = { # internal reverse proxy: tls, forwardauth, on-demand wake
      boot_phase = "network",
      enabled    = true,
      name       = "100-internal-traefik",
      type       = "internal",
      memory     = 1024,
    }
    "101" = { # SSO: authelia (OIDC + ForwardAuth) and lldap, its identity store
      boot_phase = "network",
      enabled    = true,
      name       = "101-internal-authelia",
      type       = "internal",
      memory     = 1024,
    }

    "103" = { # dashboard / service landing page
      boot_phase = "apps",
      enabled    = true,
      kind       = "lxc",
      name       = "103-internal-homepage",
      type       = "internal",
      # nfs mounts need a privileged container
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "104" = { # e-ink terminal feeds: calendar, homelab stats, arXiv
      boot_phase = "apps",
      enabled    = true,
      kind       = "lxc",
      name       = "104-internal-terminal",
      type       = "internal",
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "105" = { # observability: prometheus, loki, tempo, grafana
      boot_phase = "network",
      enabled    = true,
      name       = "105-internal-grafana",
      type       = "internal",
      # prometheus, loki, grafana: 1122 MiB peak over 7d
      memory = 2560,
      # explicit floor: tsdb head and loki chunks are working memory
      balloon = 1536,
      # remote journal buffer (1G) plus local grafana state
      disk = 16,
    }

    "109" = { # storage: NFS + SMB + Syncthing + FileBrowser, Kopia backups of it
      boot_phase = "nas",
      enabled    = true,
      name       = "109-internal-nas",
      type       = "internal",
      # kopia snapshots the whole nas, measured 624 MiB
      memory  = 3072,
      balloon = 2048,
      # nvme root: state, backups, documents
      disk = 750,
      # media and torrents on the bulk hdd (site.json)
      extra_disks = local.site.bulk == null ? [] : [{ size = local.site.bulk.sizeGiB, datastore = local.bulk_datastore }],
    }
    "110" = { # build caches: attic (nix) + sccache redis
      boot_phase = "dev",
      enabled    = true,
      kind       = "lxc",
      name       = "110-internal-cache",
      type       = "internal",
      # 63 MiB peak over 7d; redis caps itself at 256mb
      memory = 512,
      disk   = 40,
    }

    "112" = { # torrent client, egress through the router's vpn exit
      boot_phase = "media",
      enabled    = true,
      name       = "112-internal-qbittorrent",
      type       = "internal",
      memory     = 1024,
      # unfinished downloads: the size caps what torrents can take of the nvme pool
      extra_disks = [{ size = 150, datastore = var.proxmox_datastore }],
    }

    "114" = { # Hermes: Telegram agent, cloud models only, root on the lab
      boot_phase = "dev",
      enabled    = true,
      name       = "114-internal-hermes",
      type       = "internal",
      memory     = 1536,
      disk       = 60,
      machine    = "q35",
    }

    "115" = { # git forge (OIDC + SSH) and its CI runner
      boot_phase = "dev",
      enabled    = true,
      name       = "115-internal-forgejo",
      type       = "internal",
      memory     = 2048,
      # runner job images
      disk = 24,
    }
    "117" = { # ci runners for github repos (ephemeral)
      boot_phase = "dev",
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
      boot_phase = "dev",
      enabled    = true,
      name       = "118-internal-registry",
      type       = "internal",
    }
    "119" = { # arch package builds for the lsck0 pacman repo on the nas, wakes nightly
      boot_phase = "dev",
      enabled    = "onDemand",
      name       = "119-internal-archbuild",
      type       = "internal",
      # the host idles near its 80% balloon line, so a build gets the floor: 3072 left cargo 58 MiB
      memory  = 6144,
      balloon = 5120,
      cores   = 8,
      # nightly builds yield the cpu to every interactive guest (proxmox default weight is 100)
      cpu_units = 25,
      # container image, pacman cache, sources, cargo and go caches
      disk = 100,
    }

    "121" = { # document management (paperless-ngx) and paperless-ai auto-tagging
      boot_phase = "apps",
      enabled    = true,
      name       = "121-internal-paperless",
      type       = "internal",
      # ocr plus the paperless-ai node process
      memory = 3072,
      # ran at 98% of a 2048 floor
      balloon = 2560,
      # paperless-ai image alone is 8.3 GiB
      disk = 24,
    }
    "124" = { # Firefly III personal finance
      boot_phase = "apps",
      enabled    = "onDemand",
      # the 05:00 wake runs the bank import (a missed persistent timer) before it sleeps again
      cooldown   = "1h",
      name       = "124-internal-firefly",
      type       = "internal",
      memory     = 1024,
    }

    "125" = { # home automation hub
      boot_phase = "apps",
      enabled    = true,
      name       = "125-internal-homeassistant",
      type       = "internal",
      # large python process, squeezed it stalls: 739 MiB peak over 7d, so the floor stays above it
      memory  = 1536,
      balloon = 1024,
      # image alone does not fit in 8 GiB
      disk = 16,
    }

    "126" = { # automation agents / scraping
      boot_phase = "apps",
      # off until there is a use for it
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
      boot_phase = "media",
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "128-internal-jellyseerr",
      type       = "internal",
      memory     = 1024,
      # image plus local state filled 8 GiB to 80%
      disk       = 12,
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "130" = { # *arr stack: prowlarr + flaresolverr, radarr, sonarr, lidarr, bazarr, recyclarr
      boot_phase = "media",
      enabled    = true,
      name       = "130-internal-arr",
      type       = "internal",
      # five .net apps plus flaresolverr's chromium: 1510 MiB peak over 7d; they thrashed below a 512 floor each
      memory  = 3072,
      balloon = 2048,
      disk    = 16,
    }
    "134" = { # media streaming + Janitorr (deletes media unwatched for months)
      boot_phase = "media",
      enabled    = true,
      name       = "134-internal-jellyfin",
      type       = "internal",
      # vfio pins all ram, so no balloon
      memory  = 3072,
      balloon = 0,
      cores   = 4,
      # ollama model 4.4G beside jellyfin
      disk    = 24,
      machine = "q35",
      hostpci = local.site.gpu == null ? [] : ["gpu"],
    }
    "136" = { # music streaming (Subsonic API)
      boot_phase = "media",
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "136-internal-navidrome",
      type       = "internal",
      privileged = true,
      features   = "nesting=1,mount=nfs",
    }
    "138" = { # Tailscale control server (VPN mesh) + Headplane UI
      boot_phase = "network",
      # internal, not dmz: it controls mesh membership
      enabled = true,
      name    = "138-internal-headscale",
      type    = "internal",
    }

    # external: 10.200.0.0/24 dmz behind external traefik (crowdsec/waf)
    "200" = { # public reverse proxy: tls, crowdsec, anubis, waf
      boot_phase = "network",
      enabled    = true,
      name       = "200-external-traefik",
      type       = "external",
      # crowdsec oom-killed at 1024; 631 MiB peak over 7d
      memory  = 1536,
      balloon = 1024,
    }
    "203" = { # push notifications (alert delivery)
      boot_phase = "public",
      enabled    = true,
      kind       = "lxc",
      name       = "203-external-ntfy",
      type       = "external",
    }
    "204" = { # privacy metasearch
      boot_phase = "public",
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "204-external-searxng",
      type       = "external",
      # podman needs keyctl; dmz, so never privileged
      features = "nesting=1,keyctl=1",
    }
    "206" = { # encrypted pastebin
      boot_phase = "public",
      enabled    = "onDemand",
      name       = "206-external-privatebin",
      type       = "external",
    }
    "207" = { # public file sharing
      boot_phase = "public",
      enabled    = "onDemand",
      name       = "207-external-share",
      type       = "external",
      memory     = 1024,
    }
    "208" = { # Minecraft server; lazymc sleeps/wakes the server per real player logins
      boot_phase = "public",
      # off until needed. when on, lazymc stops the jvm after 30m of no players. no ballooning: a growing
      # 6g heap in a ballooned-down guest gets oom-killed, so give it a fixed 8g and let
      # the jvm's 6g heap sit resident (2g headroom for the os and jvm off-heap).
      enabled = false,
      name    = "208-external-minecraft",
      type    = "external",
      memory  = 8192,
      balloon = 8192,
      cores   = 4,
      disk    = 16,
    }
    "209" = { # app host: Docker Swarm stacks deployed by CI (Forgejo + GitHub)
      boot_phase = "public",
      enabled    = "onDemand",
      kind       = "lxc",
      name       = "209-external-hello",
      type       = "external",
      # dockerd needs keyctl; dmz, so never privileged
      features = "nesting=1,keyctl=1",
    }
    "210" = { # public lsck0 pacman mirror; vm (nfs is internal, dmz gets an ssh push instead)
      boot_phase = "dev",
      enabled    = true,
      name       = "210-external-mirror",
      type       = "external",
      # served packages tree (30G and growing), pushed from vm-119: the push adds before it deletes, so twice that
      disk = 64,
    }

    # router
    "300" = { # gateway: nat, firewall, dhcp, dns, wireguard, ddns
      boot_phase = "network",
      enabled    = true,
      name       = "luca-router",
      type       = "router",
      memory     = 1024,
      balloon    = 1024,
    }
  }
}
