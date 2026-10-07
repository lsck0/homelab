# homepage: the lab dashboard, its cards generated from every instance's and app's homepage data
{ config, lib, pkgs, inventory, nasMount, retry, setupUnit, site, catalog, lab, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  routes = catalog.internal // catalog.external;
  stateDir = "/var/lib/homepage";
  containerPort = 3000;
  # read-only behind nginx on vm-105: the widgets only query
  prometheus = (import ../../modules/telemetry.nix { inherit lib inventory; }).urls.prometheus;
  hostUrl = host: "https://${net.fqdn host}";
  urlOf = route: hostUrl routes.${route}.host;

  backendUrlOf = route: let r = routes.${route}; in "http://${inventory.${toString r.vmid}.ip}:${toString r.port}";

  # the proxmox widget checks the host against its ca pinned in site.json (init.sh); with none it is off, never unverified
  proxmoxCa = site.proxmoxCa or null;
  proxmoxCaFile = pkgs.writeText "pve-root-ca.pem" proxmoxCa;
  proxmoxCaPath = "/etc/homepage/pve-root-ca.pem";
  proxmoxWidget = { type = "proxmox"; url = "https://${frame.proxmoxApi}"; node = site.node;
    secrets = { username = "proxmox-user"; password = "proxmox-pass"; }; };

  # every widget's credentials, each as HOMEPAGE_VAR_<NAME> in the container's env: lab tokens (modules/tokens), minted
  # at runtime, and sops secrets
  widgets = lib.filter (w: w != null) (map (c: c.widget) lab.homepage) ++ lib.optional (proxmoxCa != null) proxmoxWidget;
  tokens = config.homelab.tokens.reads;
  secrets = lib.unique (lib.concatMap (w: lib.attrValues w.secrets) widgets);
  varOf = name: "HOMEPAGE_VAR_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name)}";
  credentialsOf = w: lib.mapAttrs (_: name: "{{${varOf name}}}") ((w.tokens or { }) // w.secrets);

  # a card's widget (instance.nix `homepage.<route>.widget`): its api at the route's own address unless it names one
  widgetOf = card: let w = card.widget; in
    if w == null then null
    else { inherit (w) type; url = if w.url == null then backendUrlOf card.route + w.path else w.url; }
      // credentialsOf w // w.settings;

  # dashboard groups in display order; cards come from the instances (instance.nix `homepage`) and, for Swarm, the apps
  layout = [
    { name = "Core"; icon = "mdi-server-network"; columns = 4; }
    { name = "Dev"; icon = "mdi-source-branch"; columns = 4; }
    { name = "Apps"; icon = "mdi-apps"; columns = 4; }
    # the only group with descriptions: several apps here share a medium
    { name = "Media"; icon = "mdi-play-box-multiple"; columns = 4; }
    { name = "Public"; icon = "mdi-earth"; columns = 5; }
  ];
  unknownGroups = lib.subtractLists (map (g: g.name) layout) (lib.unique (map (c: c.group) lab.homepage));
  groups = assert lib.assertMsg (unknownGroups == [ ])
    "103-internal-homepage: cards name groups without a layout here: ${toString unknownGroups}";
    map (g: g // { cards = map routeCard (lib.filter (c: c.group == g.name) lab.homepage); }) layout
    ++ lib.optional (catalog.apps != { }) {
      name = "Swarm"; icon = "mdi-docker"; columns = 4;
      cards = [ swarmCard ] ++ lib.mapAttrsToList appCard catalog.apps;
    };

  # every service listed, whatever its guest's power; a swarm app is up while its cluster is
  guestOf = r: if r.vmid == null then null else inventory.${toString r.vmid};
  stateSuffix = guest:
    if guest == null then ""
    else if !guest.powered then " (disabled)"
    else if guest.idle != null then " (on-demand)"
    else "";

  # the dot checks what the prober does (catalog.probeUrlOf)
  monitorOf = r: if r.off.probe != null then null else catalog.probeUrlOf r;

  routeCard = c: let r = routes.${c.route}; guest = guestOf r; in {
    inherit (c) name icon;
    href = urlOf c.route;
    siteMonitor = if guest != null && !guest.powered then null else monitorOf r;
    description = lib.removePrefix " " (c.description + stateSuffix guest);
    widget = widgetOf c;
  };

  # swarm apps (src/apps/), one card each, the cluster's in front; numbers from prometheus, never the docker api
  nodeCount = lib.length catalog.nodes;
  promWidget = metrics: { type = "prometheusmetric"; url = prometheus; inherit metrics; };
  # vm-105's scrape job of the nodes' cadvisor; it labels each task container with its stack
  cadvisorJob = "app-cadvisor";
  appContainers = selector: "{job=\"${cadvisorJob}\",${selector}}";
  everyApp = appContainers "swarm_stack!=\"\"";

  swarmCard = {
    name = "Swarm";
    icon = "docker";
    siteMonitor = null;
    description = "Docker Swarm, apps zone";
    widget = promWidget [
      { label = "Nodes"; query = "count(up{job=\"${cadvisorJob}\"} == 1) or vector(0)"; format.suffix = "/${toString nodeCount}"; }
      { label = "Tasks"; query = "count(container_last_seen${everyApp}) or vector(0)"; }
      { label = "Memory"; query = "sum(container_memory_working_set_bytes${everyApp})"; format.type = "bytes"; }
      { label = "Failed deploys"; query = "count(homelab_app_deploy_ok == 0) or vector(0)"; }
    ];
  };

  # the app's front door: its public root, else its first public path, else its first internal host
  mainRoute = app: let
    ofApp = side: lib.sort (x: y: x.name < y.name)
      (lib.mapAttrsToList (name: r: r // { inherit name; }) (lib.filterAttrs (_: r: r.app == app) side));
    public = ofApp catalog.external;
  in lib.head (lib.filter (r: r.path == "/") public ++ public ++ ofApp catalog.internal ++ [ null ]);

  appCard = app: a: let r = mainRoute app; ui = a.homepage or { }; own = appContainers "swarm_stack=\"${app}\""; in {
    name = ui.name or (lib.toUpper (lib.substring 0 1 app) + lib.substring 1 (-1) app);
    icon = ui.icon or "mdi-docker";
    href = if r == null then null else hostUrl r.host;
    siteMonitor = if r == null then null else monitorOf r;
    description = ui.description or "${a.repo}@${a.branch}";
    widget = promWidget ([
      { label = "Tasks"; query = "count(container_last_seen${own}) or vector(0)"; }
    ] ++ lib.optional (r != null && r.health != null) {
      # the ingress's active health check, one server per node
      label = "Healthy"; query = "sum(traefik_service_server_up{service=\"${r.name}@file\"})"; format.suffix = "/${toString nodeCount}";
    } ++ [
      { label = "Memory"; query = "sum(container_memory_working_set_bytes${own})"; format.type = "bytes"; }
      # the builder's textfile metric on vm-117 (instances/140-internal-swarm/lib/app-builder.nix)
      { label = "Deployed"; query = "time() - homelab_app_deploy_last_success_timestamp_seconds{app=\"${app}\"}"; format.type = "duration"; }
    ]);
  };

  # json is yaml: names, urls and queries need no escaping by hand
  cardYaml = c: "    - ${builtins.toJSON c.name}:\n" + lib.concatStrings (lib.mapAttrsToList (k: v: "        ${k}: ${builtins.toJSON v}\n")
    (lib.filterAttrs (k: v: k != "name" && v != null && v != "") c));
  groupYaml = g: "- ${g.name}:\n" + lib.concatMapStrings cardYaml g.cards;

  # the lab's frame (modules/infra.nix) with its widgets by card name; layout of its own in settingsYaml
  frame = import ../../modules/infra.nix { inherit net; };
  frameWidgets = {
    FritzBox = { type = "fritzbox"; url = frame.fritzbox; };
    Proxmox = if proxmoxCa == null then null else removeAttrs proxmoxWidget [ "secrets" ] // credentialsOf proxmoxWidget;
  };
  infra = {
    name = "Infra";
    cards = map (c: c // { widget = frameWidgets.${c.name} or null; }) frame.cards;
  };

  servicesYaml = pkgs.writeText "services.yaml" (lib.concatMapStrings groupYaml ([ infra ] ++ groups));

  settingsYaml = pkgs.writeText "settings.yaml" (''
    title: Homelab
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
        timezone: ${site.timeZone}
        units: metric
    - search:
        provider: custom
        url: ${urlOf "searxng"}/search?q=
        target: _blank
  '';

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" ''
    []
  '';

  # vertical centering: `safe` keeps a too tall page's top reachable, the footer leaves the flow so its mt-auto stops pinning
  customCss = pkgs.writeText "custom.css" ''
    #inner_wrapper > div { justify-content: safe center; }
    #footer { position: absolute; bottom: 0; }
  '';

  envFile = "/run/homepage.env";
  publicHost = net.fqdn routes.homepage.host;
  # a token minted after homepage started (first boot, a rotated key) reaches it within this
  envRefreshInterval = "10min";

  # the container's env: every exported widget token (token_read refuses one that could inject a line), every secret
  envRender = ''
    env_render() { # <file>
      local entry token value
      ( umask 077; : > "$1" )
      for entry in ${lib.escapeShellArgs (map (token: "${token}=${varOf token}") tokens)}; do
        token=''${entry%%=*}
        value=$(token_read "$token") || { echo "widget token $token: not exported yet or no token, skipped"; continue; }
        printf '%s=%s\n' "''${entry#*=}" "$value" >> "$1"
      done
      ${lib.concatMapStrings (secret: ''
        printf '%s=%s\n' ${varOf secret} "$(cat ${config.sops.secrets.${secret}.path})" >> "$1"
      '') secrets}
    }
  '';
in {
  sops.secrets = lib.genAttrs secrets (_: { });
  warnings = lib.optional (proxmoxCa == null)
    "vm-103: site.json pins no Proxmox CA (proxmoxCa); the homepage Proxmox widget is off. Run src/scripts/init.sh to pin it.";

  homelab.nasMounts = nasMount stateDir "homepage";

  # config files and the env from the tokens, before every start
  systemd.services.homepage-config = setupUnit {
    description = "Sync Homepage config and collect API tokens";
    # an lxc mounts nfs at boot, not on access: never write under the mountpoint
    unitConfig.RequiresMountsFor = [ stateDir ] ++ config.homelab.tokens.mountPoints;
    before = [ "podman-homepage.service" ];
    requiredBy = [ "podman-homepage.service" ];
    wantedBy = [ ];
    path = [ pkgs.coreutils ];
    script = ''
      ${envRender}
      # rename, not cp -f: a homepage render in the gap after cp unlinks the target caches empty settings
      put() { install -m 0444 "$1" "$2.tmp" && mv -f "$2.tmp" "$2"; }
      put ${servicesYaml}  ${stateDir}/services.yaml
      put ${settingsYaml}  ${stateDir}/settings.yaml
      put ${bookmarksYaml} ${stateDir}/bookmarks.yaml
      put ${widgetsYaml}   ${stateDir}/widgets.yaml
      put ${customCss}     ${stateDir}/custom.css
      # podman reads it on the host, so the keys stay off the share
      env_render ${envFile}
    '';
  };

  # tokens reach homepage at container start only; a timer, not a path unit: nfs writes raise no inotify event here
  systemd.services.homepage-env-refresh = setupUnit {
    description = "Restart Homepage when a widget token changed";
    wantedBy = [ ];
    serviceConfig = { RemainAfterExit = false; Restart = "no"; RuntimeDirectory = "homepage-env-refresh"; };
    path = [ pkgs.coreutils pkgs.diffutils pkgs.systemd ];
    script = ''
      ${envRender}
      env_render "$RUNTIME_DIRECTORY/env"
      if ! cmp -s "$RUNTIME_DIRECTORY/env" ${envFile}; then
        echo "widget tokens changed, restarting homepage"
        install -m 0600 "$RUNTIME_DIRECTORY/env" ${envFile}
        systemctl restart podman-homepage.service
      fi
    '';
  };
  systemd.timers.homepage-env-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = envRefreshInterval; OnUnitActiveSec = envRefreshInterval; };
  };

  # a fresh container serves its prebuilt page with empty settings until a revalidate rebuilds it
  systemd.services.podman-homepage.postStart = ''
    ${retry} 90 1 ${pkgs.curl}/bin/curl -sf -o /dev/null -H 'Host: ${publicHost}' http://127.0.0.1:${toString routes.homepage.port}/api/revalidate
  '';

  systemd.services.podman-homepage.restartTriggers = [
    servicesYaml settingsYaml widgetsYaml bookmarksYaml customCss
  ];

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:v1.13.2";
    ports = [ "${toString routes.homepage.port}:${toString containerPort}" ];
    volumes = [
      "${stateDir}:/app/config"
    ] ++ lib.optional (proxmoxCa != null) "${proxmoxCaFile}:${proxmoxCaPath}:ro";
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = publicHost;
    } // lib.optionalAttrs (proxmoxCa != null) {
      # node trusts the pinned proxmox ca besides its own bundle; every other widget speaks plain http in the lab
      NODE_EXTRA_CA_CERTS = proxmoxCaPath;
    };
    environmentFiles = [ envFile ];
    extraOptions = [ "--cap-add=NET_RAW" ];
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ routes.homepage.port ];

  # no login but holds every api key
  homelab.ingressOnly.ports = [ routes.homepage.port ];
}
