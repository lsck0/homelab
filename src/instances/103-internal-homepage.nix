{ config, lib, pkgs, inventory, nasMount, retry, ... }:
let
  routes = let r = import ../modules/routes.nix; in r.internal // r.external;

  ipOf = route: let r = routes.${route}; in "http://${inventory.${toString r.vmid}.ip}:${toString r.port}";
  key = name: "{{HOMEPAGE_VAR_${name}}}";
  arr = type: route: tok: { inherit type; url = ipOf route; key = key tok; };

  # dashboard entries, display order
  groups = [
    { name = "Core"; icon = "mdi-server-network"; columns = 4; entries = [
      { route = "authelia"; name = "Authelia"; icon = "authelia"; }
      { route = "lldap"; name = "LLDAP"; icon = "mdi-account-group"; }
      { route = "grafana"; name = "Grafana"; icon = "grafana";
        widget = { type = "prometheus"; url = "http://10.100.0.105:9090"; }; }
      { route = "headplane"; name = "Headplane"; icon = "headscale"; }
      { route = "nas"; name = "NAS"; icon = "mdi-nas"; }
      { route = "syncthing"; name = "Syncthing"; icon = "syncthing"; }
      { route = "kopia"; name = "Kopia"; icon = "kopia"; }
    ]; }
    { name = "Dev"; icon = "mdi-source-branch"; columns = 4; entries = [
      { route = "forgejo"; name = "Forgejo"; icon = "forgejo";
        widget = arr "gitea" "forgejo" "FORGEJO_KEY"; }
      { route = "registry-ui"; name = "Registry"; icon = "docker-moby"; }
    ]; }
    { name = "Apps"; icon = "mdi-apps"; columns = 4; entries = [
      { route = "homeassistant"; name = "Home Assistant"; icon = "home-assistant";
        widget = arr "homeassistant" "homeassistant" "HASS_KEY"; }
      { route = "huginn"; name = "Huginn"; icon = "huginn"; }
      { route = "paperless"; name = "Paperless"; icon = "paperless-ngx";
        widget = arr "paperlessngx" "paperless" "PAPERLESS_KEY"; }
      { route = "paperless-ai"; name = "Paperless AI"; icon = "paperless-ngx"; }
      { route = "firefly"; name = "Firefly III"; icon = "firefly-iii"; }
      { route = "fints"; name = "FinTS Import"; icon = "mdi-bank-transfer"; }
    ]; }
    # the only group with descriptions: several apps here share a medium
    { name = "Media"; icon = "mdi-play-box-multiple"; columns = 4; entries = [
      { route = "jellyfin"; name = "Jellyfin"; icon = "jellyfin"; desc = "Movies & shows";
        widget = arr "jellyfin" "jellyfin" "JELLYFIN_KEY" // { version = 2; enableBlocks = true; enableNowPlaying = true; }; }
      { route = "jellyseerr"; name = "Jellyseerr"; icon = "jellyseerr"; desc = "Requests";
        widget = arr "jellyseerr" "jellyseerr" "JELLYSEERR_KEY"; }
      { route = "navidrome"; name = "Navidrome"; icon = "navidrome"; desc = "Music"; }
      { route = "qbittorrent"; name = "qBittorrent"; icon = "qbittorrent"; desc = "Downloads (VPN)";
        widget = { type = "qbittorrent"; url = ipOf "qbittorrent"; username = key "QBITTORRENT_USER"; password = key "QBITTORRENT_PASS"; }; }
      { route = "sonarr"; name = "Sonarr"; icon = "sonarr"; desc = "Series & anime"; widget = arr "sonarr" "sonarr" "SONARR_KEY"; }
      { route = "radarr"; name = "Radarr"; icon = "radarr"; desc = "Movies"; widget = arr "radarr" "radarr" "RADARR_KEY"; }
      { route = "bazarr"; name = "Bazarr"; icon = "bazarr"; desc = "Subtitles"; widget = arr "bazarr" "bazarr" "BAZARR_KEY"; }
      { route = "lidarr"; name = "Lidarr"; icon = "lidarr"; desc = "Music"; widget = arr "lidarr" "lidarr" "LIDARR_KEY"; }
      { route = "prowlarr"; name = "Prowlarr"; icon = "prowlarr"; desc = "Indexers (Tor)"; widget = arr "prowlarr" "prowlarr" "PROWLARR_KEY"; }
    ]; }
    { name = "Public"; icon = "mdi-earth"; columns = 5; entries = [
      { route = "headscale"; name = "Headscale"; icon = "headscale"; }
      { route = "ntfy"; name = "ntfy"; icon = "ntfy"; }
      { route = "searxng"; name = "SearXNG"; icon = "searxng"; }
      { route = "privatebin"; name = "PrivateBin"; icon = "privatebin"; }
      { route = "share"; name = "Share"; icon = "pingvin-share"; }
      { route = "hello"; name = "Hello"; icon = "mdi-hand-wave"; }
    ]; }
  ];

  stateOf = e: inventory.${toString routes.${e.route}.vmid}.enabled or "false";

  # every service listed, whatever its vm state
  stateSuffix = state:
    if state == "onDemand" then " (on-demand)"
    else if state == "false" then " (disabled)"
    else "";
  entryYaml = e: let
    r = routes.${e.route};
    desc = lib.removePrefix " " ((e.desc or "") + stateSuffix (stateOf e));
  in lib.concatMapStrings (l: l + "\n") [
    "    - ${e.name}:"
    "        icon: ${e.icon}"
    "        href: https://${r.host}.lsck0.dev"
  ] + lib.optionalString (stateOf e != "false")
      "        siteMonitor: ${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}${r.health or ""}\n"
    + lib.optionalString (desc != "") "        description: ${desc}\n"
    + lib.optionalString (e ? widget) "        widget: ${builtins.toJSON e.widget}\n";
  groupYaml = g: "- ${g.name}:\n" + lib.concatMapStrings entryYaml g.entries;

  servicesYaml = pkgs.writeText "services.yaml" (''
    - Infra:
        - Cloudflare:
            icon: cloudflare
            href: https://dash.cloudflare.com
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
        - Traefik:
            icon: traefik
            href: https://traefik.lsck0.dev
            ping: http://10.100.0.100
            description: Internal ingress
        - Traefik DMZ:
            icon: traefik
            ping: http://10.200.0.200
            description: Public ingress
        - Terminal:
            icon: mdi-tablet-dashboard
            href: https://trmnl.com/dashboard
  '' + lib.concatMapStrings groupYaml groups);

  settingsYaml = pkgs.writeText "settings.yaml" (''
    title: home
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

  # center the dashboard vertically; footer leaves the flow so its mt-auto stops pinning content to the top
  # safe: plain center pushes overflow above the scroll origin once the page is taller than the window
  customCss = pkgs.writeText "custom.css" ''
    #inner_wrapper > div { justify-content: safe center; }
    #footer { position: absolute; bottom: 0; }
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
    # an lxc mounts nfs at boot, not on access: never write under the mountpoint
    unitConfig.RequiresMountsFor = [ "/var/lib/homepage" "/var/lib/homepage-tokens" ];
    before = [ "podman-homepage.service" ];
    requiredBy = [ "podman-homepage.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      # rename, not cp -f: cp unlinks the read-only target first, and a homepage render
      # in that gap caches empty settings (default layout, no background) until the next change
      put() { install -m 0444 "$1" "$2.tmp" && mv -f "$2.tmp" "$2"; }
      put ${servicesYaml}  /var/lib/homepage/services.yaml
      put ${settingsYaml}  /var/lib/homepage/settings.yaml
      put ${bookmarksYaml} /var/lib/homepage/bookmarks.yaml
      put ${widgetsYaml}   /var/lib/homepage/widgets.yaml
      put ${customCss}     /var/lib/homepage/custom.css

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

  # a fresh container serves its prebuilt page, settings empty; browsers only
  # rebuild it when the config hash changes, so rebuild once after every start
  systemd.services.podman-homepage.postStart = ''
    ${retry} 90 1 ${pkgs.curl}/bin/curl -sf -o /dev/null -H 'Host: homelab.lsck0.dev' http://127.0.0.1/api/revalidate
  '';

  # restart on config change
  systemd.services.podman-homepage.restartTriggers = [
    servicesYaml settingsYaml widgetsYaml bookmarksYaml customCss
  ];

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:v1.13.2";
    ports = [ "80:3000" ];
    volumes = [
      "/var/lib/homepage:/app/config"
    ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "homelab.lsck0.dev";
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
