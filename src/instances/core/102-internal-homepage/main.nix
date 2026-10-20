# homepage: the lab dashboard, its cards generated from every instance's and app's homepage data
#
# security: two pages from one set of cards. The admins' page (route homepage) shows the widgets, which the container
# fetches with every lab token; the page for everyone else (route start) holds no widget and no credential at all.
{
  config,
  lib,
  pkgs,
  inventory,
  retry,
  setupUnit,
  site,
  catalog,
  lab,
  ...
}:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  routes = catalog.internal // catalog.external;
  stateDir = "/var/lib/homepage";
  containerPort = 3000;
  # read-only behind nginx on vm-103: the widgets only query
  telemetry = import ../../../modules/telemetry.nix { inherit lib inventory; };
  inherit (telemetry.urls) prometheus;
  # only the builder's own deploy metric counts, as in vm-103's alert
  builderVm = telemetry.vmName catalog.builder;
  icons = import ./lib/icons.nix { inherit lib pkgs; };
  hostUrl = host: "https://${net.fqdn host}";
  urlOf = route: hostUrl routes.${route}.host;

  backendUrlOf =
    route:
    let
      r = routes.${route};
    in
    "http://${inventory.${toString r.vmid}.ip}:${toString r.port}";

  # the proxmox widget checks the host against its ca pinned in site.json (init.nu); with none it is off, never unverified
  proxmoxCa = site.proxmoxCa or null;
  proxmoxCaFile = pkgs.writeText "pve-root-ca.pem" proxmoxCa;
  proxmoxCaPath = "/etc/homepage/pve-root-ca.pem";
  proxmoxWidget = {
    type = "proxmox";
    url = "https://${frame.proxmoxApi}";
    inherit (site) node;
    secrets = {
      username = "proxmox-user";
      password = "proxmox-pass";
    };
  };

  # every widget's credentials, each as HOMEPAGE_VAR_<NAME> in the container's env: lab tokens (modules/tokens), minted
  # at runtime, and sops secrets
  widgets = lib.filter (w: w != null) (map (c: c.widget) lab.homepage) ++ lib.optional (proxmoxCa != null) proxmoxWidget;
  tokens = config.homelab.tokens.reads;
  tokensDir = config.homelab.tokens.dir;
  secrets = lib.unique (lib.concatMap (w: lib.attrValues w.secrets) widgets);
  varOf = name: "HOMEPAGE_VAR_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name)}";
  credentialsOf = w: lib.mapAttrs (_: name: "{{${varOf name}}}") ((w.tokens or { }) // w.secrets);

  # a card's widget (instance.nix `homepage.<route>.widget`): its api at the route's own address unless it names one
  widgetOf =
    card:
    let
      w = card.widget;
    in
    if w == null then
      null
    else
      {
        inherit (w) type;
        url = if w.url == null then backendUrlOf card.route + w.path else w.url;
      }
      // credentialsOf w
      // w.settings;

  # dashboard groups in display order; cards come from the instances (instance.nix `homepage`) and, for Swarm, the apps
  layout = [
    {
      name = "Core";
      icon = "mdi-server-network";
      columns = 4;
    }
    {
      name = "Dev";
      icon = "mdi-source-branch";
      columns = 4;
    }
    {
      name = "Apps";
      icon = "mdi-apps";
      columns = 4;
    }
    # the only group with descriptions: several apps here share a medium
    {
      name = "Media";
      icon = "mdi-play-box-multiple";
      columns = 4;
    }
    {
      name = "Public";
      icon = "mdi-earth";
      columns = 5;
    }
  ];
  unknownGroups = lib.subtractLists (map (g: g.name) layout) (lib.unique (map (c: c.group) lab.homepage));
  groups =
    assert lib.assertMsg (
      unknownGroups == [ ]
    ) "102-internal-homepage: cards name groups without a layout here: ${toString unknownGroups}";
    map (g: g // { cards = map routeCard (lib.filter (c: c.group == g.name) lab.homepage); }) layout
    ++ lib.optional (catalog.apps != { }) {
      name = "Swarm";
      icon = "mdi-docker";
      columns = 4;
      cards = [ swarmCard ] ++ lib.mapAttrsToList appCard (lib.filterAttrs (_: a: lib.elem "homepage" a.on) catalog.apps);
    };

  # every service listed, whatever its guest's power; a swarm app is up while its cluster is
  guestOf = r: if r.vmid == null then null else inventory.${toString r.vmid};
  stateSuffix =
    guest:
    if guest == null then
      ""
    else if !guest.powered then
      " (disabled)"
    else if guest.idle != null then
      " (on-demand)"
    else
      "";

  # the dot checks what the prober does (catalog.probeUrlOf)
  monitorOf = r: if lib.elem "probe" r.on then catalog.probeUrlOf r else null;

  # a powered-off guest answers neither its link, the dot nor its widget's api: each would only show an error
  routeCard =
    c:
    let
      r = routes.${c.route};
      guest = guestOf r;
      off = guest != null && !guest.powered;
    in
    {
      inherit (c) name icon;
      href = if off then null else urlOf c.route;
      siteMonitor = if off then null else monitorOf r;
      description = lib.removePrefix " " (c.description + stateSuffix guest);
      widget = if off then null else widgetOf c;
    };
  withoutWidgets = group: group // { cards = map (c: c // { widget = null; }) group.cards; };

  # swarm apps (src/instances/custom/), one card each, the cluster's in front; numbers from prometheus, never the docker api
  nodeCount = lib.length catalog.nodes;
  promWidget = metrics: {
    type = "prometheusmetric";
    url = prometheus;
    inherit metrics;
  };
  # vm-103's scrape job of the nodes' cadvisor; it labels each task container with its stack
  cadvisorJob = "app-cadvisor";
  appContainers = selector: "{job=\"${cadvisorJob}\",${selector}}";
  everyApp = appContainers "swarm_stack!=\"\"";

  swarmCard = {
    name = "Swarm";
    icon = "docker";
    siteMonitor = null;
    description = "Docker Swarm, apps zone";
    widget = promWidget [
      {
        label = "Nodes";
        query = "count(up{job=\"${cadvisorJob}\"} == 1) or vector(0)";
        # without a type homepage renders common.undefined in place of the value
        format = {
          type = "number";
          suffix = "/${toString nodeCount}";
        };
      }
      {
        label = "Tasks";
        query = "count(container_last_seen${everyApp}) or vector(0)";
      }
      {
        label = "Memory";
        query = "sum(container_memory_working_set_bytes${everyApp})";
        format.type = "bytes";
      }
      {
        label = "Failed deploys";
        query = "count(homelab_app_deploy_ok{vm=\"${builderVm}\"} == 0) or vector(0)";
      }
    ];
  };

  # the app's front door: its public root, else its first public path, else its first internal host
  mainRoute =
    app:
    let
      ofApp =
        side:
        lib.sort (x: y: x.name < y.name) (
          lib.mapAttrsToList (name: r: r // { inherit name; }) (lib.filterAttrs (_: r: r.app == app) side)
        );
      public = ofApp catalog.external;
    in
    lib.head (lib.filter (r: r.path == "/") public ++ public ++ ofApp catalog.internal ++ [ null ]);

  appCard =
    app: a:
    let
      r = mainRoute app;
      ui = a.homepage;
      own = appContainers "swarm_stack=\"${app}\"";
    in
    {
      name = ui.name or (lib.toUpper (lib.substring 0 1 app) + lib.substring 1 (-1) app);
      icon = ui.icon or "mdi-docker";
      href = if r == null then null else hostUrl r.host;
      siteMonitor = if r == null then null else monitorOf r;
      description = ui.description or "${a.repo}@${a.branch}";
      widget = promWidget (
        [
          {
            label = "Tasks";
            query = "count(container_last_seen${own}) or vector(0)";
          }
        ]
        ++ lib.optional (r != null && r.health != null) {
          # the ingress's active health check, one server per node
          label = "Healthy";
          query = "sum(traefik_service_server_up{service=\"${r.name}@file\"})";
          format = {
            type = "number";
            suffix = "/${toString nodeCount}";
          };
        }
        ++ [
          {
            label = "Memory";
            query = "sum(container_memory_working_set_bytes${own})";
            format.type = "bytes";
          }
          # the builder's textfile metric
          {
            label = "Deployed";
            query = "time() - homelab_app_deploy_last_success_timestamp_seconds{vm=\"${builderVm}\",app=\"${app}\"}";
            format.type = "duration";
          }
        ]
      );
    };

  # json is yaml: names, urls and queries need no escaping by hand
  cardYaml =
    c:
    "    - ${builtins.toJSON c.name}:\n"
    + lib.concatStrings (
      lib.mapAttrsToList (k: v: "        ${k}: ${builtins.toJSON v}\n") (
        lib.filterAttrs (k: v: k != "name" && v != null && v != "") (c // { icon = icons.src c.icon; })
      )
    );
  groupYaml = g: "- ${g.name}:\n" + lib.concatMapStrings cardYaml g.cards;

  # the lab's frame (modules/infra.nix) with its widgets by card name; layout of its own in settingsYaml
  frame = import ../../../modules/infra.nix { inherit net; };
  frameWidgets = {
    FritzBox = {
      type = "fritzbox";
      url = frame.fritzbox;
    };
    Proxmox = if proxmoxCa == null then null else removeAttrs proxmoxWidget [ "secrets" ] // credentialsOf proxmoxWidget;
  };
  infra = {
    name = "Infra";
    cards = map (c: c // { widget = frameWidgets.${c.name} or null; }) frame.cards;
  };

  servicesYamlOf =
    private:
    pkgs.writeText "services.yaml" (
      lib.concatMapStrings groupYaml (map (if private then lib.id else withoutWidgets) ([ infra ] ++ groups))
    );

  infraIcon = "mdi-server";
  iconDir = icons.dir (
    lib.unique ([ infraIcon ] ++ map (g: g.icon) groups ++ lib.concatMap (g: map (c: c.icon) g.cards) ([ infra ] ++ groups))
  );

  # served by homepage itself, like its favicon and the icons: a visit loads nothing from a third party
  background = pkgs.fetchurl {
    name = "homepage-background.jpg";
    url = "https://images.unsplash.com/photo-1506318137071-a8e063b4bec0?w=2560";
    hash = "sha256-mm2VyHSwZSqPtFYZP4TA84kSbVpIilu1GPZnJy61jvU=";
  };
  backgroundPath = "/images/background.jpg";

  settingsYaml = pkgs.writeText "settings.yaml" (
    ''
      title: Homelab
      background:
        image: ${backgroundPath}
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
          icon: ${icons.src infraIcon}
          style: row
          columns: 5
    ''
    + lib.concatMapStrings (
      g:
      lib.concatMapStrings (l: "  " + l + "\n") [
        "${g.name}:"
        "  icon: ${icons.src g.icon}"
        "  style: row"
        "  columns: ${toString g.columns}"
      ]
    ) groups
  );

  # the header's widgets, in display order; this guest's load and the house's weather (its coordinates) are the admins'
  headerWidgets = [
    {
      private = true;
      yaml = ''
        - resources:
            cpu: true
            memory: true
            uptime: true
      '';
    }
    {
      private = false;
      yaml = ''
        - datetime:
            text_size: l
            format:
              dateStyle: long
              timeStyle: short
              hour12: false
      '';
    }
    {
      private = true;
      yaml = ''
        - openmeteo:
            label: Weather
            latitude: ${builtins.toJSON site.location.latitude}
            longitude: ${builtins.toJSON site.location.longitude}
            timezone: ${site.timeZone}
            units: metric
      '';
    }
    {
      private = false;
      yaml = ''
        - search:
            provider: custom
            url: ${urlOf "searxng"}/search?q=
            target: _blank
      '';
    }
  ];
  widgetsYamlOf =
    private:
    pkgs.writeText "widgets.yaml" (lib.concatMapStrings (w: w.yaml) (lib.filter (w: private || !w.private) headerWidgets));

  bookmarksYaml = pkgs.writeText "bookmarks.yaml" ''
    []
  '';

  # vertical centering: `safe` keeps a too tall page's top reachable, the footer leaves the flow so its mt-auto stops pinning
  customCss = pkgs.writeText "custom.css" ''
    #inner_wrapper > div { justify-content: safe center; }
    #footer { position: absolute; bottom: 0; }
  '';

  # route -> whether its page is the admins', with the widgets and their credentials
  pages = {
    homepage.private = true;
    start.private = false;
  };
  configDirOf = route: "${stateDir}/${route}";
  configFilesOf = page: {
    "services.yaml" = servicesYamlOf page.private;
    "settings.yaml" = settingsYaml;
    "bookmarks.yaml" = bookmarksYaml;
    "widgets.yaml" = widgetsYamlOf page.private;
    "custom.css" = customCss;
  };
  hostOf = route: net.fqdn routes.${route}.host;
  podmanUnitOf = route: "podman-${route}.service";
  podmanUnits = map podmanUnitOf (lib.attrNames pages);

  envFile = "/run/homepage.env";
  # a token minted after homepage started (first boot, a rotated key) reaches it within this
  envRefreshInterval = "10min";
  # a hung nfs automount skips the token instead of hanging the unit; the refresh timer picks it up later
  tokenReadTimeoutS = 10;

  # the admins' container env: every exported widget token (token_read refuses one that could inject a line), every
  # secret
  envRender = ''
    env_render() { # <file>
      local entry token value
      ( umask 077; : > "$1" )
      for entry in ${lib.escapeShellArgs (map (token: "${token}=${varOf token}") tokens)}; do
        token=''${entry%%=*}
        value=$(timeout -k 5 ${toString tokenReadTimeoutS} cat ${tokensDir}/"$token".token > /dev/null && token_read "$token") || { echo "widget token $token: not exported yet or no token, skipped"; continue; }
        printf '%s=%s\n' "''${entry#*=}" "$value" >> "$1"
      done
      ${lib.concatMapStrings (secret: ''
        printf '%s=%s\n' ${varOf secret} "$(cat ${config.sops.secrets.${secret}.path})" >> "$1"
      '') secrets}
    }
  '';
in
{
  sops.secrets = lib.genAttrs secrets (_: { });
  warnings =
    lib.optional (proxmoxCa == null)
      "vm-102: site.json pins no Proxmox CA (proxmoxCa); the homepage Proxmox widget is off. Run src/scripts/init.nu to pin it.";

  # config files and the env from the tokens, before every start
  systemd.services = {
    homepage-config = setupUnit {
      description = "Sync Homepage config and collect API tokens";
      before = podmanUnits;
      requiredBy = podmanUnits;
      wantedBy = [ ];
      path = [ pkgs.coreutils ];
      script = ''
        ${envRender}
        # rename, not cp -f: a homepage render in the gap after cp unlinks the target caches empty settings
        put() { install -m 0444 "$1" "$2.tmp" && mv -f "$2.tmp" "$2"; }
        ${lib.concatStrings (
          lib.mapAttrsToList (
            route: page:
            lib.concatStrings (lib.mapAttrsToList (name: file: "put ${file} ${configDirOf route}/${name}\n") (configFilesOf page))
          ) pages
        )}
        env_render ${envFile}
      '';
    };

    # tokens reach homepage at container start only; a timer, not a path unit: nfs writes raise no inotify event here
    homepage-env-refresh = setupUnit {
      description = "Restart Homepage when a widget token changed";
      wantedBy = [ ];
      serviceConfig = {
        RemainAfterExit = false;
        Restart = "no";
        RuntimeDirectory = "homepage-env-refresh";
      };
      path = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.systemd
      ];
      script = ''
        ${envRender}
        env_render "$RUNTIME_DIRECTORY/env"
        if ! cmp -s "$RUNTIME_DIRECTORY/env" ${envFile}; then
          echo "widget tokens changed, restarting homepage"
          install -m 0600 "$RUNTIME_DIRECTORY/env" ${envFile}
          systemctl restart ${podmanUnitOf "homepage"}
        fi
        # a failed switch cancels the container starts and nothing else queues them again
        systemctl start ${toString podmanUnits}
      '';
    };
  }
  // lib.mapAttrs' (
    route: page:
    lib.nameValuePair "podman-${route}" {
      # a restarted homepage-config brings back a container that a failed switch left stopped
      wantedBy = [ "homepage-config.service" ];
      # a fresh container serves its prebuilt page with empty settings until a revalidate rebuilds it
      postStart = ''
        ${retry} 90 1 ${pkgs.curl}/bin/curl -sf -o /dev/null -H 'Host: ${hostOf route}' http://127.0.0.1:${toString routes.${route}.port}/api/revalidate
      '';
      restartTriggers = lib.attrValues (configFilesOf page);
    }
  ) pages;

  systemd.timers.homepage-env-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = envRefreshInterval;
      OnUnitActiveSec = envRefreshInterval;
    };
  };

  virtualisation.oci-containers.containers = lib.mapAttrs (
    route: page:
    let
      pinsProxmoxCa = page.private && proxmoxCa != null;
    in
    {
      image = "ghcr.io/gethomepage/homepage:v1.13.2@sha256:a0b71c8e757298d02560186bab9fbe3fc2d375c523a62cc1019177b37e48aa28";
      ports = [ "${toString routes.${route}.port}:${toString containerPort}" ];
      volumes = [
        "${configDirOf route}:/app/config"
        "${iconDir}:/app/public${icons.publicPath}:ro"
        "${background}:/app/public${backgroundPath}:ro"
      ]
      ++ lib.optional pinsProxmoxCa "${proxmoxCaFile}:${proxmoxCaPath}:ro";
      environment = {
        HOMEPAGE_ALLOWED_HOSTS = hostOf route;
      }
      // lib.optionalAttrs pinsProxmoxCa {
        # node trusts the pinned proxmox ca besides its own bundle; every other widget speaks plain http in the lab
        NODE_EXTRA_CA_CERTS = proxmoxCaPath;
      };
      environmentFiles = lib.optional page.private envFile;
      # NET_RAW: the cards' ping; the image's own healthcheck logged a line every few seconds and nothing reads it
      extraOptions = [
        "--cap-add=NET_RAW"
        "--no-healthcheck"
      ];
    }
  ) pages;

  systemd.tmpfiles.rules = map (route: "d ${configDirOf route} 0750 1000 1000 -") (lib.attrNames pages);
}
