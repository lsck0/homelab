{ pkgs, ... }:
let
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Infra:
        - Proxmox:
            icon: proxmox
            href: https://proxmox.internal.local
            description: Hypervisor
            ping: http://192.168.178.200:8006
        - Router (300):
            icon: nixos
            description: NixOS Router & DNS
            ping: http://10.100.0.1
        - Grafana (116):
            icon: grafana
            href: https://grafana.internal.local
            description: Metrics & Dashboards
            ping: http://10.100.0.116
        - CrowdSec (100):
            icon: crowdsec
            description: Security Engine
            ping: http://10.100.0.100

    - Internal:
        - Traefik (100):
            icon: traefik
            description: Reverse Proxy
            ping: http://10.100.0.100
        - Authentik (101):
            icon: authentik
            href: https://auth.internal.local
            description: Identity & SSO
            ping: http://10.100.0.101
        - Uptime Kuma (102):
            icon: uptime-kuma
            href: https://status.internal.local
            description: Status Monitoring
            ping: http://10.100.0.102
        - Forgejo (103):
            icon: forgejo
            href: https://git.internal.local
            description: Git
            ping: http://10.100.0.103
        - Forgejo Runner (104):
            icon: forgejo
            description: CI Runner
            ping: http://10.100.0.104
        - sccache (105):
            icon: mdi-cached
            description: Build Cache
            ping: http://10.100.0.105
        - Registry (106):
            icon: docker
            href: https://registry.internal.local
            description: Container Registry
            ping: http://10.100.0.106
        - NAS (107):
            icon: mdi-nas
            description: Storage
            ping: http://10.100.0.107
        - Homepage (108):
            icon: homepage
            href: https://home.internal.local
            description: Dashboard
            ping: http://10.100.0.108
        - Vaultwarden (109):
            icon: vaultwarden
            href: https://vault.internal.local
            description: Passwords
            ping: http://10.100.0.109:8080
        - Taskchampion (110):
            icon: mdi-checkbox-marked-outline
            href: https://tasks.internal.local
            description: Task Sync
            ping: http://10.100.0.110:8080
        - Nextcloud (111):
            icon: nextcloud
            href: https://cloud.internal.local
            description: Files & Calendar
            ping: http://10.100.0.111
        - Paperless (112):
            icon: paperless-ngx
            href: https://paperless.internal.local
            description: Documents
            ping: http://10.100.0.112:8080
        - Huginn (114):
            icon: huginn
            href: https://huginn.internal.local
            description: Automation
            ping: http://10.100.0.114
        - Home Assistant (115):
            icon: home-assistant
            href: https://hass.internal.local
            description: Smart Home
            ping: http://10.100.0.115
        - Wiki.js (117):
            icon: wikijs
            href: https://wiki.internal.local
            description: Knowledge Base
            ping: http://10.100.0.117
        - Headscale (119):
            icon: headscale
            href: https://hs.internal.local
            description: VPN Mesh
            ping: http://10.100.0.119

    - Media:
        - Jellyfin (113):
            icon: jellyfin
            href: https://jellyfin.internal.local
            description: Media Server
            ping: http://10.100.0.113
        - Audiobookshelf (118):
            icon: audiobookshelf
            href: https://abs.internal.local
            description: Audiobooks & Podcasts
            ping: http://10.100.0.118
        - qBittorrent (120):
            icon: qbittorrent
            href: https://torrent.internal.local
            description: Torrents
            ping: http://10.100.0.120
        - Prowlarr (121):
            icon: prowlarr
            href: https://prowlarr.internal.local
            description: Indexer Manager
            ping: http://10.100.0.121
        - Sonarr (122):
            icon: sonarr
            href: https://sonarr.internal.local
            description: TV Shows
            ping: http://10.100.0.122
        - Radarr (123):
            icon: radarr
            href: https://radarr.internal.local
            description: Movies
            ping: http://10.100.0.123

    - External:
        - Traefik (200):
            icon: traefik
            description: Reverse Proxy
            ping: http://10.200.0.200
        - Shlink (201):
            icon: shlink
            href: https://shlink.external.local
            description: Short URLs
            ping: http://10.200.0.201
        - PrivateBin (202):
            icon: privatebin
            href: https://paste.external.local
            description: Encrypted Paste
            ping: http://10.200.0.202
        - Share (203):
            icon: filebrowser
            href: https://share.external.local
            description: File Sharing
            ping: http://10.200.0.203
        - Minecraft (204):
            icon: minecraft
            description: Forge 1.20.1 — mc.lsck0.dev
            ping: http://10.200.0.204
  '';

  settingsYaml = pkgs.writeText "settings.yaml" ''
    title: Homelab
    favicon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/heimdall.png
    background:
      image: https://images.unsplash.com/photo-1502790671504-542ad42d5189?w=2560
      blur: sm
      opacity: 20
    theme: dark
    color: slate
    headerStyle: clean
    statusStyle: dot
    hideVersion: true
    layout:
      Infra:
        style: row
        columns: 4
        icon: mdi-server
      Internal:
        style: row
        columns: 4
        icon: mdi-lan
      Media:
        style: row
        columns: 3
        icon: mdi-multimedia
      External:
        style: row
        columns: 5
        icon: mdi-earth
  '';

  widgetsYaml = pkgs.writeText "widgets.yaml" ''
    - greeting:
        text_size: xl
        text: Homelab
    - datetime:
        text_size: l
        format:
          dateStyle: long
          timeStyle: short
          hour12: false
    - search:
        provider: google
        target: _blank
        focus: true
    - openmeteo:
        label: Weather
        latitude: 51.23
        longitude: 6.78
        timezone: Europe/Berlin
        units: metric
  '';

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" ''
    []
  '';
in {
  networking.hostName = "vm-108";

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [
      "/var/lib/homepage:/app/config"
      "${servicesYaml}:/app/config/services.yaml:ro"
      "${settingsYaml}:/app/config/settings.yaml:ro"
      "${bookmarksYaml}:/app/config/bookmarks.yaml:ro"
      "${widgetsYaml}:/app/config/widgets.yaml:ro"
    ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.internal.local,home.lsck0.dev";
    };
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
