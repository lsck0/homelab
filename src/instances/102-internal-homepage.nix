{ pkgs, ... }:
let
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Infrastructure:
        - FritzBox:
            icon: mdi-router-wireless
            href: http://192.168.178.1
            description: Home Router
            ping: http://192.168.178.1
        - Proxmox:
            icon: proxmox
            href: https://proxmox.internal.home
            description: Hypervisor
            ping: http://192.168.178.200:8006
        - Router:
            icon: nixos
            description: NixOS Router & DNS
            ping: http://10.100.0.1
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
            description: DNS & CDN

    - Internal:
        - Traefik:
            icon: traefik
            href: https://traefik.internal.home
            description: Reverse Proxy & Ingress
            ping: http://10.100.0.100
            widget:
              type: traefik
              url: http://10.100.0.100
        - CrowdSec:
            icon: crowdsec
            description: Intrusion Prevention
        - Authentik:
            icon: authentik
            href: https://auth.internal.home
            description: Identity Provider & SSO
            ping: http://10.100.0.101
        - Homepage:
            icon: homepage
            href: https://homepage.internal.home
            description: Dashboard
            ping: http://10.100.0.102
        - Uptime Kuma:
            icon: uptime-kuma
            href: https://status.internal.home
            description: Availability Monitoring
            ping: http://10.100.0.103
            widget:
              type: uptimekuma
              url: http://10.100.0.103:80
              slug: default
        - Forgejo:
            icon: forgejo
            href: https://git.internal.home
            description: Git Forge
            ping: http://10.100.0.104
        - Forgejo Runner:
            icon: forgejo
            description: CI/CD Runner
            ping: http://10.100.0.105
        - sccache:
            icon: mdi-cached
            description: Shared Build Cache
            ping: http://10.100.0.106
        - Registry:
            icon: docker
            href: https://registry.internal.home
            description: Container Registry
            ping: http://10.100.0.107
        - Taskchampion:
            icon: mdi-checkbox-marked-outline
            href: https://tasks.internal.home
            description: Task Sync Server
            ping: http://10.100.0.108:8080
        - Vaultwarden:
            icon: vaultwarden
            href: https://vault.internal.home
            description: Password Manager
            ping: http://10.100.0.109:8080
        - NAS:
            icon: mdi-nas
            description: NFS Storage (64 GB)
            ping: http://10.100.0.110
        - Nextcloud:
            icon: nextcloud
            href: https://cloud.internal.home
            description: Files, Calendar & Contacts
            ping: http://10.100.0.111
        - qBittorrent:
            icon: qbittorrent
            href: https://torrent.internal.home
            description: Torrent Client
            ping: http://10.100.0.112
            widget:
              type: qbittorrent
              url: http://10.100.0.112:80
        - Prowlarr:
            icon: prowlarr
            href: https://prowlarr.internal.home
            description: Indexer Manager
            ping: http://10.100.0.113
            widget:
              type: prowlarr
              url: http://10.100.0.113:80
        - Sonarr:
            icon: sonarr
            href: https://sonarr.internal.home
            description: TV Series Automation
            ping: http://10.100.0.114
            widget:
              type: sonarr
              url: http://10.100.0.114:80
        - Radarr:
            icon: radarr
            href: https://radarr.internal.home
            description: Movie Automation
            ping: http://10.100.0.115
            widget:
              type: radarr
              url: http://10.100.0.115:80
        - Navidrome:
            icon: navidrome
            href: https://music.internal.home
            description: Music Server
            ping: http://10.100.0.123
            widget:
              type: navidrome
              url: http://10.100.0.123:80
        - Kavita:
            icon: kavita
            href: https://read.internal.home
            description: Manga & Comics
            ping: http://10.100.0.124
        - Jellyfin:
            icon: jellyfin
            href: https://jellyfin.internal.home
            description: Media Streaming
            ping: http://10.100.0.116
            widget:
              type: jellyfin
              url: http://10.100.0.116:80
              enableNowPlaying: true
        - Audiobookshelf:
            icon: audiobookshelf
            href: https://abs.internal.home
            description: Audiobooks & Podcasts
            ping: http://10.100.0.117
            widget:
              type: audiobookshelf
              url: http://10.100.0.117:80
        - Paperless:
            icon: paperless-ngx
            href: https://paperless.internal.home
            description: Document Management
            ping: http://10.100.0.118:8080
            widget:
              type: paperlessngx
              url: http://10.100.0.118:8080
        - Wiki.js:
            icon: wikijs
            href: https://wiki.internal.home
            description: Knowledge Base
            ping: http://10.100.0.119
        - Huginn:
            icon: huginn
            href: https://huginn.internal.home
            description: Event-driven Automation
            ping: http://10.100.0.120
        - Home Assistant:
            icon: home-assistant
            href: https://hass.internal.home
            description: Smart Home Hub
            ping: http://10.100.0.121
            widget:
              type: homeassistant
              url: http://10.100.0.121:80
        - Grafana:
            icon: grafana
            href: https://grafana.internal.home
            description: Metrics & Dashboards
            ping: http://10.100.0.122
            widget:
              type: grafana
              url: http://10.100.0.122:80

    - External:
        - Traefik:
            icon: traefik
            description: External Reverse Proxy
            ping: http://10.200.0.200
            widget:
              type: traefik
              url: http://10.200.0.200
        - CrowdSec:
            icon: crowdsec
            description: External Intrusion Prevention
        - Headscale:
            icon: headscale
            href: https://hs.lsck0.dev
            description: Tailscale-compatible VPN
            ping: http://10.200.0.201
        - Shlink:
            icon: shlink
            href: https://shlink.external.home
            description: URL Shortener
            ping: http://10.200.0.202
        - PrivateBin:
            icon: privatebin
            href: https://paste.external.home
            description: Encrypted Pastebin
            ping: http://10.200.0.203
        - Share:
            icon: filebrowser
            href: https://share.external.home
            description: Public File Sharing
            ping: http://10.200.0.204
        - Minecraft:
            icon: minecraft
            description: Forge 1.20.1
            ping: http://10.200.0.205
            widget:
              type: minecraft
              url: udp://10.200.0.205:25565
  '';

  settingsYaml = pkgs.writeText "settings.yaml" ''
    title: Homelab
    favicon: https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/heimdall.png
    background:
      image: https://images.unsplash.com/photo-1451187580459-43490279c0fa?w=2560
      blur: sm
      opacity: 15
      saturate: 70
    theme: dark
    color: stone
    cardBlur: md
    headerStyle: clean
    statusStyle: dot
    hideVersion: true
    disableCollapse: false
    layout:
      Infrastructure:
        style: row
        columns: 4
        icon: mdi-server-network
        header: false
      Internal:
        style: row
        columns: 4
        icon: mdi-lan
      External:
        style: row
        columns: 4
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
    - openmeteo:
        label: Weather
        latitude: 51.23
        longitude: 6.78
        timezone: Europe/Berlin
        units: metric
    - search:
        provider: google
        target: _blank
  '';

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" ''
    - Proton:
        - Mail:
            - icon: mdi-email
              href: https://mail.proton.me/u/0/inbox
        - Calendar:
            - icon: mdi-calendar
              href: https://calendar.proton.me/u/0/
        - Drive:
            - icon: mdi-cloud
              href: https://drive.proton.me/u/0/RvS9PUVnaRTZn1AU8LN5eug_KJTeUNFPMkik0QFe0Qrx1JvqrTuAII0jV9Mk1KS4b0IwlLgltgKhkjrwaKCCvw==/folder/zPFLh2fkcep6PeGkzhl3quE2R0GhTOsEYn7QymVSrHT3S9i0UJA65C98AGj368bjTuAPZD2g5hoF85jM6Tgi3g==
    - Browse:
        - YouTube:
            - icon: mdi-youtube
              href: https://youtube.com
        - Twitch:
            - icon: mdi-twitch
              href: https://twitch.tv
        - Reddit:
            - icon: mdi-reddit
              href: https://reddit.com
    - Uni:
        - eCampus:
            - icon: mdi-school
              href: https://ecampus.uni-goettingen.de/h1/pages/cs/sys/portal/hisinoneStartPage.faces?page=0
  '';
in {
  networking.hostName = "vm-102";

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
      HOMEPAGE_ALLOWED_HOSTS = "homepage.internal.home,homepage.lsck0.dev";
    };
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
