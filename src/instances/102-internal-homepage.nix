{ config, pkgs, nasMount, ... }:
let
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Infra:
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
        - FritzBox:
            icon: mdi-router-wireless
            href: http://192.168.178.1
            ping: http://192.168.178.1
        - Proxmox:
            icon: proxmox
            href: https://proxmox.lsck0.dev
            ping: http://192.168.178.200:8006
        - Router:
            icon: nixos
            ping: http://10.100.0.1

    - Internal:
        - Traefik:
            icon: traefik
            href: https://traefik.lsck0.dev
            ping: http://10.100.0.100
        - Authentik:
            icon: authentik
            href: https://auth.lsck0.dev
            ping: http://10.100.0.101
        - Grafana:
            icon: grafana
            href: https://grafana.lsck0.dev
            ping: http://10.100.0.103
        - Status:
            icon: uptime-kuma
            href: https://status.lsck0.dev
            ping: http://10.100.0.104
        - NAS:
            icon: mdi-nas
            href: https://nas.lsck0.dev
            ping: http://10.100.0.105
        - sccache:
            icon: mdi-cached
        - Forgejo:
            icon: forgejo
            href: https://git.lsck0.dev
            ping: http://10.100.0.107
        - Forgejo Runner:
            icon: forgejo
            ping: http://10.100.0.108
        - Registry:
            icon: docker-moby
            href: https://registry.lsck0.dev
            ping: http://10.100.0.109
        - Tasks:
            icon: mdi-checkbox-marked-outline
            href: https://tasks.lsck0.dev
            ping: http://10.100.0.110:8080
        - Vaultwarden:
            icon: vaultwarden
            href: https://vault.lsck0.dev
            ping: http://10.100.0.111:8080
        - Nextcloud:
            icon: nextcloud
            href: https://cloud.lsck0.dev
            ping: http://10.100.0.112
        - Paperless:
            icon: paperless-ngx
            href: https://paperless.lsck0.dev
            ping: http://10.100.0.113:8080
        - Huginn:
            icon: huginn
            href: https://huginn.lsck0.dev
            ping: http://10.100.0.114
        - Home Assistant:
            icon: home-assistant
            href: https://hass.lsck0.dev
            ping: http://10.100.0.115
        - Wiki.js:
            icon: wikijs
            href: https://wiki.lsck0.dev
            ping: http://10.100.0.116
        - qBittorrent:
            icon: qbittorrent
            href: https://torrent.lsck0.dev
            ping: http://10.100.0.117
        - Prowlarr:
            icon: prowlarr
            href: https://prowlarr.lsck0.dev
            ping: http://10.100.0.118
        - Radarr:
            icon: radarr
            href: https://radarr.lsck0.dev
            ping: http://10.100.0.119
        - Sonarr:
            icon: sonarr
            href: https://sonarr.lsck0.dev
            ping: http://10.100.0.120
        - Jellyfin:
            icon: jellyfin
            href: https://jellyfin.lsck0.dev
            ping: http://10.100.0.121
        - Audiobookshelf:
            icon: audiobookshelf
            href: https://abs.lsck0.dev
            ping: http://10.100.0.122
        - Navidrome:
            icon: navidrome
            href: https://music.lsck0.dev
            ping: http://10.100.0.123
        - Kavita:
            icon: kavita
            href: https://read.lsck0.dev
            ping: http://10.100.0.124
    - External:
        - Ext Traefik:
            icon: traefik
            href: https://ext-traefik.lsck0.dev
            ping: http://10.200.0.200
        - Headscale:
            icon: headscale
            href: https://hs.lsck0.dev
            ping: http://10.200.0.201
        - Shlink:
            icon: shlink
            href: https://shlink.lsck0.dev
            ping: http://10.200.0.202
        - PrivateBin:
            icon: privatebin
            href: https://paste.lsck0.dev
            ping: http://10.200.0.203
        - Share:
            icon: filebrowser
            href: https://share.lsck0.dev
            ping: http://10.200.0.204
        - Minecraft:
            icon: minecraft
            ping: http://10.200.0.205
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
    disableCollapse: true
    fiveColumns: true
    layout:
      Infra:
        style: row
        columns: 4
      Internal:
        style: row
        columns: 5
      External:
        style: row
        columns: 3
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
    []
  '';
in {
  networking.hostName = "vm-102";

  sops.secrets."proxmox-user" = {};
  sops.secrets."proxmox-pass" = {};

  fileSystems = nasMount "/var/lib/homepage" "homepage"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # Build env file from token files on NAS before container starts
  systemd.services.homepage-config = {
    description = "Sync Homepage config and collect API tokens";
    before = [ "podman-homepage.service" ];
    requiredBy = [ "podman-homepage.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      cp -f ${servicesYaml}  /var/lib/homepage/services.yaml
      cp -f ${settingsYaml}  /var/lib/homepage/settings.yaml
      cp -f ${bookmarksYaml} /var/lib/homepage/bookmarks.yaml
      cp -f ${widgetsYaml}   /var/lib/homepage/widgets.yaml

      # Collect API tokens from shared NAS directory into env file
      ENV_FILE="/var/lib/homepage/homepage.env"
      : > "$ENV_FILE"
      for f in /var/lib/homepage-tokens/*.token; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .token)"
        # Convert e.g. "forgejo-key" to "HOMEPAGE_VAR_FORGEJO_KEY"
        varname="HOMEPAGE_VAR_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
        echo "''${varname}=$(cat "$f")" >> "$ENV_FILE"
      done

      echo "HOMEPAGE_VAR_PROXMOX_USER=$(cat ${config.sops.secrets."proxmox-user".path})" >> "$ENV_FILE"
      echo "HOMEPAGE_VAR_PROXMOX_PASS=$(cat ${config.sops.secrets."proxmox-pass".path})" >> "$ENV_FILE"

      chmod 600 "$ENV_FILE"
    '';
  };

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [
      "/var/lib/homepage:/app/config"
    ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "homepage.lsck0.dev";
    };
    environmentFiles = [ "/var/lib/homepage/homepage.env" ];
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
