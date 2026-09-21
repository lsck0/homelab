{ config, lib, pkgs, inventory, nasMount, ... }:
let
  routes = let r = import ../modules/routes.nix; in r.internal // r.external;

  # dashboard entries, in display order. `route` links the card to its host
  # in modules/routes.nix; the VM's state in instances.tf decides whether it
  # is shown (disabled: hidden), pinged (always on) or marked on-demand (no
  # ping, which would only ever show it as down).
  groups = [
    { name = "Core"; entries = [
      { route = "authelia"; name = "Authelia"; icon = "authelia"; desc = "SSO"; }
      { route = "lldap"; name = "LLDAP"; icon = "mdi-account-group"; desc = "Directory"; }
      { route = "grafana"; name = "Grafana"; icon = "grafana"; desc = "Monitoring"; }
      { route = "uptime-kuma"; name = "Status"; icon = "uptime-kuma"; desc = "Uptime"; }
      { route = "kopia"; name = "Kopia"; icon = "kopia"; desc = "Backups"; }
      { route = "wazuh"; name = "Wazuh"; icon = "wazuh"; desc = "Security"; }
      { route = "nas"; name = "NAS"; icon = "mdi-nas"; desc = "Files"; }
      { route = "syncthing"; name = "Syncthing"; icon = "syncthing"; desc = "Device sync"; }
      { route = "attic"; name = "Attic"; icon = "nixos"; desc = "Nix cache"; }
      { route = "qbittorrent"; name = "qBittorrent"; icon = "qbittorrent"; desc = "Downloads (Tor)"; }
    ]; }
    { name = "Dev"; entries = [
      { route = "forgejo"; name = "Forgejo"; icon = "forgejo"; desc = "Git (SSO)"; }
      { route = "registry-ui"; name = "Registry"; icon = "docker-moby"; desc = "Docker registry"; }
      { route = "hello"; name = "Hello"; icon = "mdi-hand-wave"; desc = "CI/CD demo (Forgejo)"; }
      { route = "hello-gh"; name = "Hello GH"; icon = "github"; desc = "CI/CD demo (GitHub)"; }
    ]; }
    { name = "Apps"; entries = [
      { route = "vaultwarden"; name = "Vaultwarden"; icon = "vaultwarden"; desc = "Passwords"; }
      { route = "nextcloud"; name = "Nextcloud"; icon = "nextcloud"; desc = "Cloud"; }
      { route = "paperless"; name = "Paperless"; icon = "paperless-ngx"; desc = "Documents"; }
      { route = "paperless-ai"; name = "Paperless AI"; icon = "paperless-ngx"; desc = "Auto-tagging"; }
      { route = "firefly"; name = "Firefly III"; icon = "firefly-iii"; desc = "Finance"; }
      { route = "wikijs"; name = "Wiki.js"; icon = "wikijs"; desc = "Wiki"; }
      { route = "homeassistant"; name = "Home Assistant"; icon = "home-assistant"; desc = "Home"; }
      { route = "huginn"; name = "Huginn"; icon = "huginn"; desc = "Agents"; }
    ]; }
    { name = "Media"; entries = [
      { route = "jellyseerr"; name = "Jellyseerr"; icon = "jellyseerr"; desc = "Requests"; }
      { route = "jellyfin"; name = "Jellyfin"; icon = "jellyfin"; desc = "Movies & shows"; }
      { route = "navidrome"; name = "Navidrome"; icon = "navidrome"; desc = "Music"; }
      { route = "audiobookshelf"; name = "Audiobookshelf"; icon = "audiobookshelf"; desc = "Audiobooks"; }
      { route = "kavita"; name = "Kavita"; icon = "kavita"; desc = "Books & manga"; }
      { route = "suwayomi"; name = "Suwayomi"; icon = "suwayomi"; desc = "Manga downloads"; }
      { route = "radarr"; name = "Radarr"; icon = "radarr"; desc = "Movies"; }
      { route = "sonarr"; name = "Sonarr"; icon = "sonarr"; desc = "Series & anime"; }
      { route = "lidarr"; name = "Lidarr"; icon = "lidarr"; desc = "Music"; }
      { route = "bookshelf"; name = "Bookshelf"; icon = "readarr"; desc = "Ebooks"; }
      { route = "prowlarr"; name = "Prowlarr"; icon = "prowlarr"; desc = "Indexers"; }
      { route = "bazarr"; name = "Bazarr"; icon = "bazarr"; desc = "Subtitles"; }
    ]; }
    { name = "Public"; entries = [
      { route = "headscale"; name = "Headscale"; icon = "headscale"; desc = "VPN mesh"; }
      { route = "ntfy"; name = "ntfy"; icon = "ntfy"; desc = "Notifications"; }
      { route = "shlink"; name = "Shlink"; icon = "shlink"; desc = "Short links"; }
      { route = "searxng"; name = "SearXNG"; icon = "searxng"; desc = "Search"; }
      { route = "privatebin"; name = "PrivateBin"; icon = "privatebin"; desc = "Paste"; }
      { route = "share"; name = "Share"; icon = "pingvin-share"; desc = "File sharing"; }
    ]; }
  ];

  stateOf = e: inventory.${toString routes.${e.route}.vmid}.enabled or "false";

  # Every declared service is listed, in declaration order, whatever state its
  # VM is in. A card that vanishes when its VM is switched off hides exactly
  # the thing worth seeing, and leaves the remaining cards looking shuffled.
  # The dot carries the state instead: every entry is pinged, so a disabled or
  # sleeping VM shows up red rather than disappearing.
  stateSuffix = state:
    if state == "onDemand" then " (on-demand)"
    else if state == "false" then " (disabled)"
    else "";
  entryYaml = e: let r = routes.${e.route}; state = stateOf e; in lib.concatMapStrings (l: l + "\n") [
    "    - ${e.name}:"
    "        icon: ${e.icon}"
    "        href: https://${r.host}.lsck0.dev"
    "        description: ${e.desc}${stateSuffix state}"
    "        ping: ${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}"
  ];
  groupYaml = g: "- ${g.name}:\n" + lib.concatMapStrings entryYaml g.entries;

  servicesYaml = pkgs.writeText "services.yaml" (''
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
        - Traefik:
            icon: traefik
            href: https://traefik.lsck0.dev
            ping: http://10.100.0.100
        - Router:
            icon: nixos
            ping: http://10.100.0.1
            description: NixOS Gateway
        - Terminal:
            icon: mdi-tablet-dashboard
            href: https://trmnl.com/dashboard
            description: E-ink dashboard (TRMNL)
  '' + lib.concatMapStrings groupYaml groups);

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
        columns: 5
      Core:
        style: row
        columns: 5
      Dev:
        style: row
        columns: 4
      Apps:
        style: row
        columns: 4
      Media:
        style: row
        columns: 6
      Public:
        style: row
        columns: 6
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
  networking.hostName = "vm-103";

  sops.secrets."proxmox-user" = {};
  sops.secrets."proxmox-pass" = {};

  fileSystems = nasMount "/var/lib/homepage" "homepage"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # build env file from token files on NAS before container starts
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
      for f in /var/lib/homepage-tokens/*.token /var/lib/homepage-tokens/external/*.token; do
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

  # restart the container when any config file changes, so a deploy that only
  # edits services/settings/widgets actually reloads (config is copied in by
  # homepage-config, which is requiredBy this unit).
  systemd.services.podman-homepage.restartTriggers = [
    servicesYaml settingsYaml widgetsYaml bookmarksYaml
  ];

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:v1.12.3";
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

  # Homepage has no login of its own and carries every service's API key in its
  # widgets, so only the ingress (which puts Authelia in front) may reach it.
  homelab.ingressOnly.ports = [ 80 ];
}
