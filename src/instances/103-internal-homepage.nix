{ config, lib, pkgs, inventory, nasMount, ... }:
let
  routes = let r = import ../modules/routes.nix; in r.internal // r.external;

  ipOf = route: let r = routes.${route}; in "http://${inventory.${toString r.vmid}.ip}:${toString r.port}";
  key = name: "{{HOMEPAGE_VAR_${name}}}";
  arr = type: route: tok: { inherit type; url = ipOf route; key = key tok; };

  # dashboard entries, display order
  groups = [
    { name = "Media"; icon = "mdi-play-box-multiple"; columns = 4; entries = [
      { route = "jellyfin"; name = "Jellyfin"; icon = "jellyfin"; desc = "Movies & shows";
        widget = arr "jellyfin" "jellyfin" "JELLYFIN_KEY" // { enableBlocks = true; enableNowPlaying = true; }; }
      { route = "jellyseerr"; name = "Jellyseerr"; icon = "jellyseerr"; desc = "Requests";
        widget = arr "jellyseerr" "jellyseerr" "JELLYSEERR_KEY"; }
      { route = "navidrome"; name = "Navidrome"; icon = "navidrome"; desc = "Music"; }
      { route = "qbittorrent"; name = "qBittorrent"; icon = "qbittorrent"; desc = "Downloads (VPN)";
        widget = { type = "qbittorrent"; url = ipOf "qbittorrent"; username = key "QBITTORRENT_USER"; password = key "QBITTORRENT_PASS"; }; }
      { route = "radarr"; name = "Radarr"; icon = "radarr"; desc = "Movies"; widget = arr "radarr" "radarr" "RADARR_KEY"; }
      { route = "sonarr"; name = "Sonarr"; icon = "sonarr"; desc = "Series & anime"; widget = arr "sonarr" "sonarr" "SONARR_KEY"; }
      { route = "lidarr"; name = "Lidarr"; icon = "lidarr"; desc = "Music"; widget = arr "lidarr" "lidarr" "LIDARR_KEY"; }
      { route = "prowlarr"; name = "Prowlarr"; icon = "prowlarr"; desc = "Indexers (Tor)"; widget = arr "prowlarr" "prowlarr" "PROWLARR_KEY"; }
      { route = "bazarr"; name = "Bazarr"; icon = "bazarr"; desc = "Subtitles"; widget = arr "bazarr" "bazarr" "BAZARR_KEY"; }
    ]; }
    { name = "Apps"; icon = "mdi-apps"; columns = 4; entries = [
      { route = "homeassistant"; name = "Home Assistant"; icon = "home-assistant"; desc = "Home";
        widget = arr "homeassistant" "homeassistant" "HASS_KEY"; }
      { route = "paperless"; name = "Paperless"; icon = "paperless-ngx"; desc = "Documents";
        widget = arr "paperlessngx" "paperless" "PAPERLESS_KEY"; }
      { route = "paperless-ai"; name = "Paperless AI"; icon = "paperless-ngx"; desc = "Auto-tagging"; }
      { route = "firefly"; name = "Firefly III"; icon = "firefly-iii"; desc = "Finance"; }
      { route = "huginn"; name = "Huginn"; icon = "huginn"; desc = "Agents"; }
    ]; }
    { name = "Dev"; icon = "mdi-source-branch"; columns = 4; entries = [
      { route = "forgejo"; name = "Forgejo"; icon = "forgejo"; desc = "Git";
        widget = arr "gitea" "forgejo" "FORGEJO_KEY"; }
      { route = "registry-ui"; name = "Registry"; icon = "docker-moby"; desc = "Images"; }
      { route = "attic"; name = "Attic"; icon = "nixos"; desc = "Nix cache"; }
      { route = "hello"; name = "Hello"; icon = "mdi-hand-wave"; desc = "Swarm demo (Forgejo)"; }
      { route = "hello-gh"; name = "Hello GH"; icon = "github"; desc = "Swarm demo (GitHub)"; }
    ]; }
    { name = "Core"; icon = "mdi-server-network"; columns = 4; entries = [
      { route = "grafana"; name = "Grafana"; icon = "grafana"; desc = "Metrics & alerts";
        widget = { type = "prometheus"; url = "http://10.100.0.105:9090"; }; }
      { route = "authelia"; name = "Authelia"; icon = "authelia"; desc = "SSO"; }
      { route = "lldap"; name = "LLDAP"; icon = "mdi-account-group"; desc = "Users & groups"; }
      { route = "headplane"; name = "Headplane"; icon = "headscale"; desc = "VPN mesh admin"; }
      { route = "nas"; name = "NAS"; icon = "mdi-nas"; desc = "Files"; }
      { route = "syncthing"; name = "Syncthing"; icon = "syncthing"; desc = "Device sync"; }
      { route = "kopia"; name = "Kopia"; icon = "kopia"; desc = "Backups"; }
    ]; }
    { name = "Public"; icon = "mdi-earth"; columns = 5; entries = [
      { route = "headscale"; name = "Headscale"; icon = "headscale"; desc = "VPN control"; }
      { route = "ntfy"; name = "ntfy"; icon = "ntfy"; desc = "Notifications"; }
      { route = "searxng"; name = "SearXNG"; icon = "searxng"; desc = "Search"; }
      { route = "privatebin"; name = "PrivateBin"; icon = "privatebin"; desc = "Paste"; }
      { route = "share"; name = "Share"; icon = "pingvin-share"; desc = "File sharing"; }
    ]; }
  ];

  stateOf = e: inventory.${toString routes.${e.route}.vmid}.enabled or "false";

  # every service listed, whatever its vm state
  stateSuffix = state:
    if state == "onDemand" then " (on-demand)"
    else if state == "false" then " (disabled)"
    else "";
  entryYaml = e: let r = routes.${e.route}; state = stateOf e; in lib.concatMapStrings (l: l + "\n") [
    "    - ${e.name}:"
    "        icon: ${e.icon}"
    "        href: https://${r.host}.lsck0.dev"
    "        description: ${e.desc}${stateSuffix state}"
    "        siteMonitor: ${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}"
  ] + lib.optionalString (e ? widget) "        widget: ${builtins.toJSON e.widget}\n";
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

  settingsYaml = pkgs.writeText "settings.yaml" (''
    title: lsck0 lab
    favicon: https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/homepage.svg
    background:
      image: https://images.unsplash.com/photo-1506318137071-a8e063b4bec0?w=2560
      blur: md
      brightness: 50
      saturate: 60
    theme: dark
    color: slate
    cardBlur: xl
    headerStyle: boxedWidgets
    statusStyle: dot
    iconStyle: theme
    useEqualHeights: true
    hideVersion: true
    target: _blank
    quicklaunch:
      searchDescriptions: true
      hideVisitURL: true
    layout:
      Infra:
        icon: mdi-server
        style: row
        columns: 5
  '' + lib.concatMapStrings (g: lib.concatMapStrings (l: "  " + l + "\n") [
    "${g.name}:"
    "  icon: ${g.icon}"
    "  style: row"
    "  columns: ${toString g.columns}"
  ]) groups);

  widgetsYaml = pkgs.writeText "widgets.yaml" ''
    - resources:
        label: vm-103
        cpu: true
        memory: true
        uptime: true
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

  # env file from nas tokens before start
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

  # restart on config change
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

  # no login but holds every api key
  homelab.ingressOnly.ports = [ 80 ];
}
