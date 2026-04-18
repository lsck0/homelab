{ pkgs, nasMount, ... }:
let
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Links:
        - Proton Mail:
            icon: mdi-email
            href: https://mail.proton.me/u/0/inbox
        - Proton Calendar:
            icon: mdi-calendar
            href: https://calendar.proton.me/u/0/
        - Proton Drive:
            icon: mdi-cloud
            href: https://drive.proton.me
        - YouTube:
            icon: mdi-youtube
            href: https://youtube.com
        - Twitch:
            icon: mdi-twitch
            href: https://twitch.tv
        - Reddit:
            icon: mdi-reddit
            href: https://reddit.com
        - eCampus:
            icon: mdi-school
            href: https://ecampus.uni-goettingen.de

    - Infra:
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
        - FritzBox:
            icon: mdi-router-wireless
            href: http://192.168.178.1
            ping: http://192.168.178.1
        - Router:
            icon: nixos
            ping: http://10.100.0.1
        - Proxmox:
            icon: proxmox
            href: https://proxmox.internal
            ping: http://192.168.178.200:8006
        - Traefik:
            icon: traefik
            href: https://traefik.internal
            ping: http://10.100.0.100
            widget:
              type: traefik
              url: http://10.100.0.100:8080
        - Authentik:
            icon: authentik
            href: https://auth.internal
            ping: http://10.100.0.101
        - Grafana:
            icon: grafana
            href: https://grafana.internal
            ping: http://10.100.0.104
        - Status:
            icon: uptime-kuma
            href: https://status.internal
            ping: http://10.100.0.103
            widget:
              type: uptimekuma
              url: http://10.100.0.103
              slug: homelab
        - NAS:
            icon: mdi-nas
            href: https://nas.internal
            ping: http://10.100.0.111

    - Services:
        - Forgejo:
            icon: forgejo
            href: https://git.internal
            ping: http://10.100.0.105
            widget:
              type: gitea
              url: http://10.100.0.105
              key: {{HOMEPAGE_VAR_FORGEJO_KEY}}
        - Forgejo Runner:
            icon: forgejo
            ping: http://10.100.0.106
        - Registry:
            icon: docker-moby
            href: https://registry.internal
            ping: http://10.100.0.108
        - sccache:
            icon: mdi-cached
        - Nextcloud:
            icon: nextcloud
            href: https://cloud.internal
            ping: http://10.100.0.112
            widget:
              type: nextcloud
              url: http://10.100.0.112
              username: {{HOMEPAGE_VAR_NEXTCLOUD_USER}}
              password: {{HOMEPAGE_VAR_NEXTCLOUD_PASS}}
        - Vaultwarden:
            icon: vaultwarden
            href: https://vault.internal
            ping: http://10.100.0.110:8080
        - Paperless:
            icon: paperless-ngx
            href: https://paperless.internal
            ping: http://10.100.0.119:8080
            widget:
              type: paperlessngx
              url: http://10.100.0.119:8080
              key: {{HOMEPAGE_VAR_PAPERLESS_KEY}}
        - Wiki.js:
            icon: wikijs
            href: https://wiki.internal
            ping: http://10.100.0.120
        - Home Assistant:
            icon: home-assistant
            href: https://hass.internal
            ping: http://10.100.0.122
        - Huginn:
            icon: huginn
            href: https://huginn.internal
            ping: http://10.100.0.121
        - Tasks:
            icon: mdi-checkbox-marked-outline
            href: https://tasks.internal
            ping: http://10.100.0.109:8080

    - Media:
        - Jellyfin:
            icon: jellyfin
            href: https://jellyfin.internal
            ping: http://10.100.0.117
        - qBittorrent:
            icon: qbittorrent
            href: https://torrent.internal
            ping: http://10.100.0.113
            widget:
              type: qbittorrent
              url: http://10.100.0.113
        - Sonarr:
            icon: sonarr
            href: https://sonarr.internal
            ping: http://10.100.0.115
            widget:
              type: sonarr
              url: http://10.100.0.115
              key: 626adc3d01074b2989e95d1b31f8bc02
        - Radarr:
            icon: radarr
            href: https://radarr.internal
            ping: http://10.100.0.116
            widget:
              type: radarr
              url: http://10.100.0.116
              key: ec5dbde1269d4ab59a3714e175a7f2e6
        - Prowlarr:
            icon: prowlarr
            href: https://prowlarr.internal
            ping: http://10.100.0.114
            widget:
              type: prowlarr
              url: http://10.100.0.114
              key: c21a45cc3d624c48a315d0960de8937c
        - Navidrome:
            icon: navidrome
            href: https://music.internal
            ping: http://10.100.0.123
        - Audiobookshelf:
            icon: audiobookshelf
            href: https://abs.internal
            ping: http://10.100.0.118
        - Kavita:
            icon: kavita
            href: https://read.internal
            ping: http://10.100.0.124

    - External:
        - Ext Traefik:
            icon: traefik
            href: https://traefik.external
            ping: http://10.200.0.200
            widget:
              type: traefik
              url: http://10.200.0.200:8080
        - Headscale:
            icon: headscale
            href: https://hs.lsck0.dev
            ping: http://10.200.0.201
        - Shlink:
            icon: shlink
            href: https://shlink.external
            ping: http://10.200.0.202
            widget:
              type: shlink
              url: http://10.200.0.202
              key: {{HOMEPAGE_VAR_SHLINK_KEY}}
        - PrivateBin:
            icon: privatebin
            href: https://paste.external
            ping: http://10.200.0.203
        - Share:
            icon: filebrowser
            href: https://share.external
            ping: http://10.200.0.204
        - Minecraft:
            icon: minecraft
            ping: http://10.200.0.205
            widget:
              type: minecraft
              url: udp://10.200.0.205
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
      Links:
        style: row
        columns: 7
        header: false
      Infra:
        style: row
        columns: 5
      Services:
        style: row
        columns: 5
      Media:
        style: row
        columns: 4
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
    - resources:
        cpu: true
        memory: true
        uptime: true
        disk: /
  '';

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" ''
    []
  '';
in {
  networking.hostName = "vm-102";

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
      HOMEPAGE_ALLOWED_HOSTS = "homepage.internal,homepage.lsck0.dev";
    };
    environmentFiles = [ "/var/lib/homepage/homepage.env" ];
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
