{ config, pkgs, nasMount, ... }:
let
  # Only enabled, running services are listed (disabled baseline VMs would show
  # red). Widgets are kept only where credentials exist (Proxmox, FritzBox);
  # elsewhere a plain href avoids "API Error" cards. On-demand services get no
  # ping (they idle-stop, which would show red).
  servicesYaml = pkgs.writeText "services.yaml" ''
    - Infra:
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
            description: DNS & CDN
        - FritzBox:
            icon: mdi-router-wireless
            href: http://192.168.178.1
            ping: http://192.168.178.1
            widget:
              type: fritzbox
              url: http://192.168.178.1
        - Proxmox:
            icon: proxmox
            href: https://proxmox.lsck0.dev
            ping: http://192.168.178.200:8006
            widget:
              type: proxmox
              url: https://192.168.178.200:8006
              username: "{{HOMEPAGE_VAR_PROXMOX_USER}}"
              password: "{{HOMEPAGE_VAR_PROXMOX_PASS}}"
              node: luca-server
        - Router:
            icon: nixos
            ping: http://10.100.0.1
            description: NixOS Gateway

    - Internal:
        - Traefik:
            icon: traefik
            href: https://traefik.lsck0.dev
            ping: http://10.100.0.100
        - Authelia:
            icon: authelia
            href: https://auth.lsck0.dev
            ping: http://10.100.0.128:9091
            description: SSO
        - LLDAP:
            icon: mdi-account-group
            href: https://lldap.lsck0.dev
            ping: http://10.100.0.133:17170
            description: Directory
        - Grafana:
            icon: grafana
            href: https://grafana.lsck0.dev
            ping: http://10.100.0.103
            description: Monitoring
        - Status:
            icon: uptime-kuma
            href: https://status.lsck0.dev
            ping: http://10.100.0.104
            description: Uptime
        - NAS:
            icon: mdi-nas
            href: https://nas.lsck0.dev
            ping: http://10.100.0.105
            description: NFS / SMB / backups
        - sccache:
            icon: mdi-cached
            ping: http://10.100.0.106
            description: Build Cache
        - Forgejo:
            icon: forgejo
            href: https://git.lsck0.dev
            ping: http://10.100.0.107
            description: Git (SSO)
        - Registry:
            icon: docker-moby
            href: https://registry-ui.lsck0.dev
            ping: http://10.100.0.109
            description: Docker Registry
        - Attic:
            icon: nixos
            href: https://attic.lsck0.dev
            ping: http://10.100.0.131:8080
            description: Nix Cache
        - Jellyseerr:
            icon: jellyseerr
            href: https://requests.lsck0.dev
            ping: http://10.100.0.136
            description: Media Requests
        - Bazarr:
            icon: bazarr
            href: https://subs.lsck0.dev
            ping: http://10.100.0.137
            description: Subtitles
        - Actual Budget:
            icon: actual-budget
            href: https://budget.lsck0.dev
            description: Budget (on-demand)
        - Firefly III:
            icon: firefly-iii
            href: https://firefly.lsck0.dev
            description: Finance (on-demand)

    - External:
        - Ext Traefik:
            icon: traefik
            href: https://ext-traefik.lsck0.dev
            ping: http://10.200.0.200
        - Headscale:
            icon: headscale
            href: https://hs.lsck0.dev
            ping: http://10.200.0.201
            description: VPN Mesh
        - SearXNG:
            icon: searxng
            href: https://search.lsck0.dev
            description: Metasearch (on-demand)
        - Shlink:
            icon: shlink
            href: https://shlink.lsck0.dev
            ping: http://10.200.0.203
            description: URL Shortener
        - PrivateBin:
            icon: privatebin
            href: https://paste.lsck0.dev
            description: Encrypted Paste (on-demand)
        - Share:
            icon: filebrowser
            href: https://share.lsck0.dev
            description: File Sharing (on-demand)
        - ntfy:
            icon: ntfy
            href: https://ntfy.lsck0.dev
            ping: http://10.200.0.206
            description: Notifications
        - Hello:
            icon: mdi-hand-wave
            href: https://hello.lsck0.dev
            ping: http://10.200.0.208
            description: Demo App
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
        columns: 4
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
        provider: custom
        url: https://search.lsck0.dev/search?q=
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

      ENV_FILE="/var/lib/homepage/homepage.env"
      : > "$ENV_FILE"
      for f in /var/lib/homepage-tokens/*.token; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .token)"
        varname="HOMEPAGE_VAR_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
        echo "''${varname}=$(cat "$f")" >> "$ENV_FILE"
      done

      echo "HOMEPAGE_VAR_PROXMOX_USER=$(cat ${config.sops.secrets."proxmox-user".path})" >> "$ENV_FILE"
      echo "HOMEPAGE_VAR_PROXMOX_PASS=$(cat ${config.sops.secrets."proxmox-pass".path})" >> "$ENV_FILE"

      chmod 600 "$ENV_FILE"
    '';
  };

  # Restart the container when any config file changes, so a deploy that only
  # edits services/settings/widgets actually reloads (config is copied in by
  # homepage-config, which is requiredBy this unit).
  systemd.services.podman-homepage.restartTriggers = [
    servicesYaml settingsYaml widgetsYaml bookmarksYaml
  ];

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [
      "/var/lib/homepage:/app/config"
    ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "homepage.lsck0.dev";
      NODE_TLS_REJECT_UNAUTHORIZED = "0";
    };
    environmentFiles = [ "/var/lib/homepage/homepage.env" ];
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
