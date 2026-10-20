# observability: prometheus, loki, tempo and pyroscope behind their doors, grafana with the lab's boards and alerts
#
# security: senders reach nginx doors, never a store; a push door sets the tenant from the sender's address, so an app
# node writes only the tenants of the apps its cluster runs. The stores listen on loopback.
{
  config,
  pkgs,
  lib,
  inventory,
  nasMountRo,
  site,
  catalog,
  lab,
  ...
}:
let
  telemetry = import ../../../modules/telemetry.nix { inherit lib inventory; };
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  limits = import ../../../modules/limits { inherit lib; };
  ntfy = import ../../../modules/ntfy.nix;
  notifications = import ./lib/notifications.nix {
    inherit lib;
    grafanaUrl = grafanaRootUrl;
  };
  inherit (telemetry) vmName ports;

  tempoGrpcPort = 9095;
  lokiGrpcPort = 9096;
  pyroscopeGrpcPort = 9097;
  # tempo's memberlist default is 7946; nothing joins this ring, it only must not collide
  pyroscopeMemberlistPort = 7947;
  blackboxPort = 9115;
  froniusListen = "127.0.0.1:9118";
  loopback = "127.0.0.1";
  # grafana behind its own nginx door, which names the user and the role
  grafanaLocalPort = 3000;
  grafanaRootUrl = "https://${net.fqdn lab.routes.grafana.host}";

  # the single binary dials its own components at the address its rings advertise, eth0 by default; loopback keeps
  # them, and the gossip, on the host
  pyroscopeRings = [
    "compactor.ring.instance-addr"
    "distributor.ring.instance-addr"
    "overrides-exporter.ring.instance-addr"
    "query-frontend.instance-addr"
    "query-scheduler.ring.instance-addr"
    "store-gateway.sharding-ring.instance-addr"
    "ingester.lifecycler.addr"
    "memberlist.advertise-addr"
    "memberlist.bind-addr"
  ];
  pyroscopeDir = "/var/lib/pyroscope";
  lokiDir = "/var/lib/loki";
  tempoDir = "/var/lib/tempo";

  # logs, profiles and the received journals are kept as long: a profile never outlives the logs around it
  observabilityRetentionDays = 14;
  observabilityRetention = "${toString (observabilityRetentionDays * 24)}h";
  journalRemoteDir = "/var/log/journal/remote";
  journalRemoteMaxUse = "1G";
  journalRemoteFileSize = "32M";
  # loki's default 5000 cut the template's log panels short
  lokiMaxLines = 10000;
  # the template's datasource timeout: 7d and 30d unique-visitor queries parse every access log line
  lokiQueryTimeoutSeconds = 60;
  # the span metrics' cardinality is bounded here: any lab guest may send spans, and a span name is a label
  tempoMaxActiveSeries = 20000;
  mibOf = bytes: bytes / (1024.0 * 1024);
  tenantLabel = "tenant";

  prometheusRetentionTime = "10y";
  # energy history, ~1GB a month, is ended by the size, not the 10y; the disk also holds the system, journal-remote's 1G
  # and loki's two weeks
  nonPrometheusGiB = 24;
  # the cap the store had on the nas: a smaller one would delete its oldest months at the first start
  prometheusRetentionFloorGiB = 50;
  prometheusRetentionGiB =
    let
      gib = lab.instances.${telemetry.collectorVmid}.config.vm.diskGiB - nonPrometheusGiB;
    in
    assert lib.assertMsg (gib >= prometheusRetentionFloorGiB)
      "103-internal-grafana: diskGiB leaves prometheus ${toString gib}GB, below the ${toString prometheusRetentionFloorGiB}GB its history needs";
    gib;

  # the template's dashboards rate over [1m], four samples at 15s; the lab default of 1m leaves one
  appScrapeInterval = "15s";
  nodeJob = "homelab-node-exporter";
  cadvisorJob = "app-cadvisor";
  proxmoxVm = "proxmox";

  monitoringUnits = [
    "grafana"
    "prometheus"
    "nginx"
    "loki"
    "tempo"
    "pyroscope"
    "promtail"
    "systemd-journal-remote"
    "prometheus-blackbox-exporter"
  ];
  # [.]: a literal dot that needs no backslash, which systemd's ExecStart and a promql string would each unescape
  monitoringUnitsRegex = "(${lib.concatStringsSep "|" monitoringUnits})[.]service";

  # the largest burst its store admits from one tenant
  pushBodyBytes = {
    loki = lib.max limits.lab.logBurstBytes (limits.tenant.logBurstLines * limits.tenant.logLineBytes);
    otlp = limits.tenant.traceBurstBytes;
    pyroscope = limits.tenant.profileBurstBytes;
  };

  # the browser attributes kept: a route and a status explain a slow or failed request, the rest could be a person
  frontendSpanAttributes = [
    "http.request.method"
    "http.response.status_code"
    "http.route"
    "url.path"
    "server.address"
    "error.type"
    "exception.type"
    "component"
  ];
  frontendResourceAttributes = [
    "service.name"
    "service.version"
    "deployment.environment.name"
    "telemetry.sdk.name"
    "telemetry.sdk.language"
    "telemetry.sdk.version"
    "browser.platform"
    "browser.mobile"
  ];
  frontendMetricAttributes = [ "web_vital.name" ];
  frontendIntakeMemoryMiB = 128;

  ntfyHeartbeatQuery = "template=yes&message=${lib.escapeURL "vm-103 alerting alive, {{.status}}"}";
  telegramMessage = "{{ template \"${notifications.telegramTemplateName}\" . }}";

  boardsDir = "grafana-dashboards";
  boardPathOf = name: "${boardsDir}/${name}.json";
  homelabBoardPath = boardPathOf "homelab";
  appBoardsDir = "grafana-apps";
  appImportsMount = "/var/lib/app-dashboards";
  appImportScanS = 60;

  guest = vmid: inventory.${toString vmid} or (throw "103-internal-grafana: the inventory has no guest ${toString vmid}");
  guestAt =
    ip:
    lib.findFirst (v: v.ip == ip) (throw "103-internal-grafana: the inventory has no guest at ${ip}") (
      lib.attrValues inventory
    );
  ingressOf = zone: guest net.zones.${zone}.ingress;
  collector = guest telemetry.collectorVmid;
  router = lib.findFirst (v: v.type == "router") null (lib.attrValues inventory);
  # the router's leg in the internal zone
  routerAddress = collector.gateway;
  # where the operators ssh from: their own devices, the operator guest, and the router's leg in each zone, the source
  # a guest sees for a connection the router masquerades
  operatorSources = [
    net.wan.workstation
    net.wan.notebook
    net.wireguard.subnet
    (guest lab.roles.operator).ip
  ]
  ++ map (z: z.routerIp) (lib.attrValues net.zones);
  # the lab's own forced-command logins, each from the one guest its key allows: the archbuild push to the dmz mirror and
  # the deploy controller's stacks to the swarm guests
  serviceLogins = [
    {
      user = "archrepo";
      source =
        (lib.findFirst (g: lib.hasSuffix "-archbuild" g.name) (throw "no archbuild guest") (lib.attrValues inventory)).ip;
    }
    {
      user = "root";
      source = (guest lab.roles.app-builder).ip;
    }
  ];
  # powered and never asleep: a probe or an alert on anything else would wake it or alarm while it sleeps
  awake = v: v.powered && v.idle == null;

  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  appNodes = map guest (lib.sort (a: b: lib.toInt a < lib.toInt b) appNodeIds);

  # every app ships its containers' logs; only the ones sending traces or profiles pass the other push doors
  appSenders = lib.concatLists (
    lib.mapAttrsToList (
      _: c:
      lib.concatMap (
        id:
        map (app: {
          inherit ((guest id)) ip;
          tenant = telemetry.tenantOf app;
        }) (lib.attrNames c.apps)
      ) c.workerIds
    ) catalog.clusters
  );
  signalTenants = [
    telemetry.labTenant
  ]
  ++ lib.concatMap (c: map telemetry.tenantOf (lib.attrNames (lib.filterAttrs (_: telemetry.sendsSignals) c.apps))) (
    lib.attrValues catalog.clusters
  );
  labSenders = [
    loopback
  ]
  ++ map (v: v.ip) (lib.attrValues (lib.filterAttrs (id: v: v.type != "router" && !(lib.elem id appNodeIds)) inventory));

  # a powered-off guest is not scraped; an idle one is, labeled, so the offline alert knows it sleeps on purpose
  nodeTargets =
    lib.mapAttrsToList (_: v: {
      address = v.ip;
      vm = vmName v;
      idle = v.idle != null;
    }) (lib.filterAttrs (_: v: v.type != "router" && v.powered) inventory)
    ++ lib.optional (router != null) {
      address = routerAddress;
      vm = vmName router;
      idle = false;
    }
    ++ [
      {
        address = site.lan.proxmox;
        vm = proxmoxVm;
        idle = false;
      }
    ];
  guestsExpectedUp = "up{job=\"${nodeJob}\",idle=\"\"}";

  services = lib.filterAttrs (_: s: s.vmid == null || (guest s.vmid).powered) catalog.services;
  servicesOn = feature: lib.filterAttrs (_: s: s.on.${feature}) services;
  isApp = s: s.app != null;
  exportersOf = s: if s.on.metrics then s.metrics else { };
  # an app's exporter answers on any node of its cluster's routing mesh (one, or each sample counts once per node)
  exporterNodeOf = s: if isApp s then guestAt (lib.head s.cluster.nodes) else guest s.vmid;
  exporterJobOf =
    key: s: name:
    "${if isApp s then "app" else "service"}-${key}-${name}";
  # each exporter in its own job: one above its budget fails its own scrape, nobody else's
  exporterScrapeConfigs = lib.concatLists (
    lib.mapAttrsToList (
      key: s:
      lib.mapAttrsToList (name: m: {
        job_name = exporterJobOf key s name;
        scrape_interval = appScrapeInterval;
        metrics_path = m.path;
        sample_limit = limits.tenant.scrapeSamples;
        static_configs = [
          {
            targets = [ "${(exporterNodeOf s).ip}:${toString m.port}" ];
            labels = {
              ${if isApp s then "app" else "service"} = key;
              vm = vmName (exporterNodeOf s);
            };
          }
        ];
      }) (exportersOf s)
    ) services
  );

  appScrapeConfigs = lib.optionals (catalog.apps != { }) [
    {
      job_name = cadvisorJob;
      scrape_interval = appScrapeInterval;
      static_configs = map (node: {
        targets = [ "${node.ip}:${toString catalog.swarm.cadvisorPort}" ];
        labels.vm = vmName node;
      }) appNodes;
      metric_relabel_configs = [
        # every systemd slice is a cgroup too; only containers carry a name, the rest is cardinality
        {
          source_labels = [
            "__name__"
            "name"
          ];
          regex = "container_.*;";
          action = "drop";
        }
        {
          source_labels = [ "name" ];
          regex = telemetry.swarmTaskPatterns.service;
          target_label = "swarm_service";
        }
        {
          source_labels = [ "name" ];
          regex = telemetry.swarmTaskPatterns.stack;
          target_label = "swarm_stack";
        }
      ];
    }
    {
      job_name = config.homelab.appTelemetry.shipperJob;
      scrape_interval = appScrapeInterval;
      static_configs = map (node: {
        targets = [ "${node.ip}:${toString ports.promtail}" ];
        labels.vm = vmName node;
      }) appNodes;
    }
  ];

  traefikTargetOf = zone: "${(ingressOf zone).ip}:${toString net.ports.traefikMetrics}";
  ingressZones = [
    "internal"
    "external"
  ];
  # an exporter beside each ingress's traefik (modules/traefik), labeled with its guest; anubis guards public routes only
  ingressScrapeConfig = job: port: zones: {
    job_name = job;
    static_configs = map (zone: {
      targets = [ "${(ingressOf zone).ip}:${toString port}" ];
      labels.vm = vmName (ingressOf zone);
    }) zones;
  };
  anubisZones = lib.filter (zone: lib.any (r: lib.elem "anubis" r.on) (lib.attrValues catalog.${zone})) ingressZones;
  ingressScrapeConfigs = [
    (ingressScrapeConfig "ingress-logs" ports.promtail ingressZones)
    (ingressScrapeConfig "crowdsec" ports.crowdsecMetrics ingressZones)
  ]
  ++ lib.optional (anubisZones != [ ]) (ingressScrapeConfig "anubis" ports.anubisMetrics anubisZones);

  # through the zone's ingress, as a visitor reaches it
  httpProbes =
    lib.mapAttrsToList
      (name: r: {
        inherit name;
        vm = vmName (guest r.vmid);
        target = catalog.probeUrlOf r;
      })
      (
        lib.filterAttrs (_: r: r.vmid != null && lib.elem "probe" r.on && awake (guest r.vmid)) (
          catalog.internal // catalog.external
        )
      );
  # a tcp route at the backend the router forwards to; udp has no generic probe
  tcpProbes =
    lib.mapAttrsToList
      (
        name: r:
        let
          node = if r.vmid != null then guest r.vmid else guestAt (lib.head r.nodes);
        in
        {
          inherit name;
          vm = vmName node;
          target = "${node.ip}:${toString r.port}";
        }
      )
      (
        lib.filterAttrs (
          _: r: r.protocol == "tcp" && lib.elem "probe" r.on && (r.vmid == null || awake (guest r.vmid))
        ) catalog.l4
      );
  # an idle guest's host port at its own address, which wakes nothing: down while asleep, so service_down holds it to
  # the guest being up. Only where the guest grants the collector the port, or the probe is a guard refusal
  grantsCollector =
    vmid: port:
    lib.any (g: g.to == toString vmid && lib.elem telemetry.collectorVmid g.from && lib.elem port g.tcp) lab.grants;
  backendProbes =
    lib.mapAttrsToList
      (name: r: {
        inherit name;
        vm = vmName (guest r.vmid);
        target = "${(guest r.vmid).ip}:${toString r.port}";
      })
      (
        lib.filterAttrs (
          _: r:
          r.vmid != null
          && lib.elem "probe" r.on
          && (guest r.vmid).powered
          && (guest r.vmid).idle != null
          && grantsCollector r.vmid r.port
        ) (catalog.internal // catalog.external)
      );
  inherit (telemetry) upstreamJob;
  probesOf = protocol: if protocol == "http" then httpProbes else tcpProbes;
  probeJobOf = job: module: probes: {
    job_name = job;
    metrics_path = "/probe";
    params.module = [ module ];
    scrape_interval = "60s";
    static_configs = map (p: {
      targets = [ p.target ];
      labels = {
        service = p.name;
        inherit (p) vm;
      };
    }) probes;
    relabel_configs = [
      {
        source_labels = [ "__address__" ];
        target_label = "__param_target";
      }
      {
        source_labels = [ "__param_target" ];
        target_label = "instance";
      }
      {
        target_label = "__address__";
        replacement = "${loopback}:${toString blackboxPort}";
      }
    ];
  };
  probeJob = protocol: probeJobOf "blackbox-${protocol}" "${protocol}_up" (probesOf protocol);

  labRules = telemetry.alertsOf (
    import ./lib/rules.nix {
      ingressJobs = map (j: j.job_name) ingressScrapeConfigs;
      inherit
        lib
        telemetry
        ntfy
        catalog
        nodeJob
        guestsExpectedUp
        monitoringUnitsRegex
        services
        exportersOf
        exporterJobOf
        upstreamJob
        ;
      edgeTraefikTarget = traefikTargetOf "external";
      proxmoxAddress = site.lan.proxmox;
      inherit proxmoxVm operatorSources serviceLogins;
    }
  );
  # the rules instances and apps declare over their own metrics, a powered-off guest's none; an app's uid carries the app
  ownRules =
    lib.mapAttrs (_: a: removeAttrs a [ "vmid" ]) (lib.filterAttrs (_: a: (guest a.vmid).powered) lab.alerts)
    // lib.concatMapAttrs (app: a: lib.mapAttrs' (name: lib.nameValuePair "app_${app}_${name}") a.alerts) catalog.apps;
  rulesTwice = lib.intersectLists (lib.attrNames labRules) (lib.attrNames ownRules);
  rules =
    assert lib.assertMsg (rulesTwice == [ ]) "103-internal-grafana: alert uids declared twice: ${toString rulesTwice}";
    labRules // ownRules;

  # an evaluation that errors or finds no data has no value A, and grafana keeps a template it cannot expand raw: such
  # a text reads each value as grafana's own marker for a missing one instead
  valueAction = "[{][{][^}]*[$]values[^}]*[}][}]";
  missingValue = "[no value]";
  valueSafe =
    text:
    let
      parts = builtins.split valueAction text;
    in
    if lib.length parts == 1 then
      text
    else
      "{{ if $values.A }}${text}{{ else }}${
        lib.concatMapStrings (p: if lib.isList p then missingValue else p) parts
      }{{ end }}";
  ruleLabelsOf = r: { inherit (r) severity category; } // lib.optionalAttrs r.telegram { notify = "telegram"; };

  # query A thresholded by C
  ruleOf = uid: r: {
    inherit uid;
    inherit (r) title for;
    condition = "C";
    data = [
      {
        refId = "A";
        relativeTimeRange = {
          from = r.rangeSeconds;
          to = 0;
        };
        datasourceUid = r.datasource;
        model = {
          refId = "A";
          inherit (r) expr;
          instant = true;
        }
        // lib.optionalAttrs (r.datasource == "loki") { queryType = "instant"; };
      }
      {
        refId = "C";
        datasourceUid = "__expr__";
        model = {
          refId = "C";
          type = "threshold";
          expression = "A";
          conditions = [
            {
              evaluator = {
                type = r.op;
                params = [ r.threshold ];
              };
            }
          ];
        };
      }
    ];
    noDataState = r.noData;
    execErrState = r.execErr;
    labels =
      let
        unshared = lib.subtractLists notifications.ruleLabels (lib.attrNames (ruleLabelsOf r));
      in
      assert lib.assertMsg (
        unshared == [ ]
      ) "103-internal-grafana: lib/notifications.nix ruleLabels lacks ${toString unshared}";
      ruleLabelsOf r;
    annotations = lib.mapAttrs (_: valueSafe) { inherit (r) summary description; } // telemetry.categories.${r.category};
  };

  # straight to ntfy's own port on vm-201: an edge fault must not swallow the alerts (instance.nix grant there)
  ntfyRoute = catalog.external.ntfy;
  ntfyBase = "http://${(guest ntfyRoute.vmid).ip}:${toString ntfyRoute.port}";
  ntfyReceiver = uid: topic: query: {
    inherit uid;
    type = "webhook";
    settings = {
      url = "${ntfyBase}/${topic}?${query}";
      httpMethod = "POST";
      username = "grafana";
      password = config.sops.placeholder.ntfy-grafana-password;
    };
  };
  contactPoints = {
    apiVersion = 1;
    contactPoints = [
      {
        orgId = 1;
        name = "ntfy";
        receivers = [
          (ntfyReceiver "ntfy_cp" ntfy.topics.alerts notifications.ntfyQuery // { disableResolveMessage = false; })
        ];
      }
      # silence is the signal; a resolve message would be one more heartbeat
      {
        orgId = 1;
        name = "heartbeat";
        receivers = [
          (ntfyReceiver "heartbeat_cp" ntfy.topics.heartbeat ntfyHeartbeatQuery // { disableResolveMessage = true; })
        ];
      }
      {
        orgId = 1;
        name = "telegram";
        receivers = [
          {
            uid = "telegram_cp";
            type = "telegram";
            settings = {
              bottoken = config.sops.placeholder.telegram-bot-token;
              chatid = config.sops.placeholder.telegram-chat-id;
              parse_mode = "HTML";
              message = telegramMessage;
              disable_web_page_preview = true;
            };
            disableResolveMessage = false;
          }
        ];
      }
    ];
  };

  energyModel = import ../../../modules/energy { inherit pkgs; };
  feedIo = import ../../../modules/feeds { inherit pkgs; };
  python =
    name: libraries: file:
    pkgs.writers.writePython3Bin name {
      inherit libraries;
      flakeIgnore = [
        "E501"
        "E203"
        "W503"
      ];
    } (builtins.readFile file);

  froniusExporter = python "fronius-exporter" [ ] ./lib/fronius-exporter.py;
  inverter = site.lan.inverter != "";
  # local copy: a missing nas token must fail one scrape, not prometheus
  hassScrapeToken = "/run/prometheus-hass/token";
  homeAssistant = catalog.internal.homeassistant;
  homeAssistantPowered = (guest homeAssistant.vmid).powered;

  spotPrice = python "spot-price" [ energyModel feedIo ] ./lib/spot-price.py;
  spotPriceState = "/var/lib/spot-price";
  inherit (config.homelab) textfileDir;
  spotPriceFile = "spot_price";
  alertsExportFile = "grafana_alerts";

  # generated, so a board cannot drift from the queries it shares (energy_model, the alert expressions)
  dashboardPython = pkgs.python3.withPackages (_: [ energyModel ]);
  dashboard =
    name: script: config:
    pkgs.runCommand "${name}.json"
      {
        config = builtins.toJSON config;
        passAsFile = [ "config" ];
      }
      ''
        PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${script} "$configPath" $out
      '';
  edgeHost = "vm-${net.zones.external.ingress}";
  homelabDashboard = dashboard "homelab" ./lib/dashboards/homelab.py {
    uid = telemetry.homelabDashboardUid;
    inherit nodeJob guestsExpectedUp edgeHost;
    ssoHost = "vm-${toString lab.routes.authelia.vmid}";
    nasVm = vmName (guest lab.roles.nas);
    hostVm = proxmoxVm;
  };
  energyDashboard = pkgs.runCommand "energy.json" { } ''
    PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${./lib/dashboards/energy.py} $out
  '';
  boardRoutes =
    zone: routes:
    lib.mapAttrsToList (name: r: {
      inherit name;
      host = net.fqdn r.host;
      ingress = "vm-${net.zones.${zone}.ingress}";
      instance = traefikTargetOf zone;
    }) routes;
  lokiJsonData = {
    maxLines = lokiMaxLines;
    timeout = lokiQueryTimeoutSeconds;
  };
  tenantHeader = {
    httpHeaderName1 = telemetry.tenantHeader;
  };
  # the tenant is public, yet grafana's module warns of a store leak for any secureJsonData not read from a file
  tenantSecureJsonOf = uid: tenant: {
    httpHeaderValue1 = "$__file{${pkgs.writeText "grafana-tenant-${uid}" tenant}}";
  };
  labTempoUid = "tempo";
  lokiTenants = lib.concatStringsSep "|" ([ telemetry.labTenant ] ++ map telemetry.tenantOf (lib.attrNames catalog.apps));
  tenantDatasources = lib.concatLists (
    lib.mapAttrsToList (
      app: a:
      [
        {
          name = "Loki ${app}";
          type = "loki";
          access = "proxy";
          url = "http://${loopback}:${toString ports.lokiLocal}";
          uid = "loki-${app}";
          secureJsonData = tenantSecureJsonOf "loki-${app}" (telemetry.tenantOf app);
          jsonData = lokiJsonData // tenantHeader;
        }
      ]
      ++ lib.optional (lib.elem "traces" a.on) {
        name = "Tempo ${app}";
        type = "tempo";
        access = "proxy";
        url = "http://${loopback}:${toString ports.tempo}";
        uid = "tempo-${app}";
        secureJsonData = tenantSecureJsonOf "tempo-${app}" (telemetry.tenantOf app);
        jsonData = tenantHeader // {
          tracesToLogsV2 = {
            datasourceUid = "loki-${app}";
            tags = [
              {
                key = "host.name";
                value = "host";
              }
              {
                key = "container.name";
                value = "container_name";
              }
              # no semconv names a unit: a lab service that wants the link sets this attribute
              {
                key = "systemd.unit";
                value = "unit";
              }
            ];
            # batch exporters send a span seconds after its log lines
            spanStartTimeShift = "-5m";
            spanEndTimeShift = "5m";
          };
          serviceMap.datasourceUid = "prometheus";
          nodeGraph.enabled = true;
        };
      }
      ++ lib.optional (lib.elem "profiles" a.on) {
        name = "Pyroscope ${app}";
        type = "grafana-pyroscope-datasource";
        access = "proxy";
        url = "http://${loopback}:${toString ports.pyroscopeLocal}";
        uid = "pyroscope-${app}";
        secureJsonData = tenantSecureJsonOf "pyroscope-${app}" (telemetry.tenantOf app);
        jsonData = tenantHeader;
      }
    ) catalog.apps
  );

  keepKeys = keys: [ "keep_keys(attributes, [${lib.concatMapStringsSep ", " builtins.toJSON keys}])" ];
  frontendIntakeConfig = pkgs.writeText "otel-frontend.json" (
    builtins.toJSON {
      receivers.otlp.protocols.http = {
        endpoint = "0.0.0.0:${toString ports.otlpFrontend}";
        traces_url_path = "${telemetry.frontendPath}/v1/traces";
        logs_url_path = "${telemetry.frontendPath}/v1/logs";
        metrics_url_path = "${telemetry.frontendPath}/v1/metrics";
        include_metadata = true;
        max_request_body_size = limits.frontend.bodyBytes;
      };
      processors = {
        memory_limiter = {
          check_interval = "1s";
          limit_mib = frontendIntakeMemoryMiB;
          spike_limit_mib = frontendIntakeMemoryMiB / 4;
        };
        # metrics have no tenant downstream: the app becomes a label
        "attributes/tenant".actions = [
          {
            key = tenantLabel;
            from_context = "metadata.x-scope-orgid";
            action = "upsert";
          }
        ];
        "transform/allow" = {
          error_mode = "ignore";
          trace_statements = [
            {
              context = "resource";
              statements = keepKeys frontendResourceAttributes;
            }
            {
              context = "span";
              statements = keepKeys frontendSpanAttributes;
            }
          ];
          log_statements = [
            {
              context = "resource";
              statements = keepKeys frontendResourceAttributes;
            }
            {
              context = "log";
              statements = keepKeys frontendSpanAttributes;
            }
          ];
          metric_statements = [
            {
              context = "resource";
              statements = keepKeys frontendResourceAttributes;
            }
            {
              context = "datapoint";
              statements = keepKeys (frontendSpanAttributes ++ frontendMetricAttributes ++ [ tenantLabel ]);
            }
          ];
        };
        # one batch per tenant, so the header goes out with the right one
        batch.metadata_keys = [ "x-scope-orgid" ];
      };
      extensions.headers_setter.headers = [
        {
          key = telemetry.tenantHeader;
          from_context = "x-scope-orgid";
          action = "upsert";
        }
      ];
      exporters = {
        "otlphttp/tempo" = {
          endpoint = "http://${loopback}:${toString ports.otlpHttpLocal}";
          auth.authenticator = "headers_setter";
        };
        "otlphttp/loki" = {
          endpoint = "http://${loopback}:${toString ports.lokiLocal}/otlp";
          auth.authenticator = "headers_setter";
        };
        "otlphttp/prometheus".endpoint = "http://${loopback}:${toString ports.prometheusLocal}/api/v1/otlp";
      };
      service = {
        extensions = [ "headers_setter" ];
        pipelines =
          let
            common = [
              "memory_limiter"
              "transform/allow"
              "batch"
            ];
          in
          {
            traces = {
              receivers = [ "otlp" ];
              processors = common;
              exporters = [ "otlphttp/tempo" ];
            };
            logs = {
              receivers = [ "otlp" ];
              processors = common;
              exporters = [ "otlphttp/loki" ];
            };
            metrics = {
              receivers = [ "otlp" ];
              processors = [
                "memory_limiter"
                "attributes/tenant"
                "transform/allow"
                "batch"
              ];
              exporters = [ "otlphttp/prometheus" ];
            };
          };
      };
    }
  );

  serviceBoards = lib.mapAttrs (
    key: s:
    let
      app = isApp s;
      routesIn = routes: lib.filterAttrs (name: _: lib.elem name s.routes) routes;
    in
    {
      name = key;
      routes = boardRoutes "internal" (routesIn catalog.internal) ++ boardRoutes "external" (routesIn catalog.external);
      forwards =
        if routesIn catalog.forwarded == { } || router == null then
          null
        else
          {
            host = router.name;
            loki = "loki";
            routes = lib.mapAttrsToList (name: r: {
              inherit name;
              inherit (r) protocol;
              port = r.publicPort;
            }) (routesIn catalog.forwarded);
          };
      deploys = app;
      idle = app && s.idle.stopAfter != null;
      containers = if app then "swarm_stack=\"${key}\"" else null;
      vm = if app then null else vmName (guest s.vmid);
      reservation = if app then catalog.apps.${key}.reservation else null;
      logs =
        if !s.on.logs then
          null
        else if app then
          "swarm_stack=\"${key}\""
        else
          "host=\"vm-${toString s.vmid}\"";
      loki = if app then "loki-${key}" else "loki";
      metricsJobs = map (exporterJobOf key s) (lib.attrNames (exportersOf s));
      tenant = if app then telemetry.tenantOf key else telemetry.labTenant;
      # no nixos service sends traces or profiles yet; when one does it gets a tenant like an app's
      tempo = if app && s.on.traces then "tempo-${key}" else null;
      pyroscope = if app && s.on.profiles then "pyroscope-${key}" else null;
      frontend = app && s.on.frontend;
      template = exportersOf s ? server;
      budget = limits.tenant;
      routeLimit = limits.route;
      inherit cadvisorJob nodeJob;
      inherit (config.homelab.appTelemetry) shipperJob;
      rateWindow = "5m";
    }
  ) (servicesOn "dashboard");
  serviceDashboards = lib.mapAttrs (name: board: dashboard name ./lib/dashboards/service.py board) serviceBoards;
  overviewDashboard = dashboard "services" ./lib/dashboards/service.py { services = lib.attrValues serviceBoards; };
  # the lab's own services share one folder; its name is no valid app name, so no app's folder can take it
  boardFolderOf = key: if isApp services.${key} then key else "Lab services";
  dashboards = {
    homelab = homelabDashboard;
    energy = energyDashboard;
    services = overviewDashboard;
  };

  addressPattern = lib.replaceStrings [ "." ] [ "\\." ];
  # admins administer grafana, every other user it admits views; root on this guest is root in grafana too
  grafanaUserHeader = "Remote-User";
  grafanaRoleHeader = "X-Grafana-Role";
  grafanaCallers = lib.concatMapStringsSep "|" addressPattern [
    (ingressOf "internal").ip
    loopback
  ];
  grafanaIdentityMap = ''
    map $remote_addr $grafana_user {
      default "";
      "~^(${grafanaCallers})$" $http_remote_user;
    }
    map "$remote_addr $http_remote_groups" $grafana_role {
      default Viewer;
      "~^${addressPattern loopback} " Admin;
      "~^(${grafanaCallers}) (.*,)?${catalog.access.admins}(,.*)?$" Admin;
    }
  '';
  grafanaDoor = {
    listen = [
      {
        addr = "0.0.0.0";
        port = ports.grafana;
      }
    ];
    # the ingress's body limit governs
    extraConfig = "client_max_body_size 0;";
    locations."/" = {
      proxyPass = "http://${loopback}:${toString grafanaLocalPort}";
      proxyWebsockets = true;
      recommendedProxySettings = true;
      extraConfig = ''
        proxy_set_header ${grafanaUserHeader} $grafana_user;
        proxy_set_header ${grafanaRoleHeader} $grafana_role;
      '';
    };
  };

  pushTenantMap = ''
    map "$remote_addr $http_x_scope_orgid" $push_tenant {
      default "";
    ${lib.concatMapStrings (s: "  \"${s.ip} ${s.tenant}\" ${s.tenant};\n") appSenders}  "~^(${
      lib.concatMapStringsSep "|" addressPattern labSenders
    }) " ${telemetry.labTenant};
    }
    map $push_tenant $signal_tenant {
      default "";
    ${lib.concatMapStrings (tenant: "  ${tenant} ${tenant};\n") (lib.unique signalTenants)}}
    map $http_x_scope_orgid $read_tenant { "" ${telemetry.labTenant}; default $http_x_scope_orgid; }
  '';
  pushDoor =
    {
      door,
      body,
      local,
      grpc ? false,
    }:
    {
      listen = [
        {
          addr = "0.0.0.0";
          port = ports.${door};
        }
      ];
      # grpc is http/2; in clear text nginx takes it by prior knowledge, which is what grpc clients send
      extraConfig = "client_max_body_size ${toString body};" + lib.optionalString grpc "\nhttp2 on;";
      locations = {
        "/".return = "404";
      }
      // lib.genAttrs (map (path: "= ${path}") telemetry.pushPaths.${door}) (_: {
        extraConfig = ''
          limit_except POST { deny all; }
          if ($push_tenant = "") { return 403; }
        ''
        + lib.optionalString (door != "lokiPush") ''
          if ($signal_tenant = "") { return 403; }
        ''
        + (
          if grpc then
            ''
              grpc_set_header ${telemetry.tenantHeader} $push_tenant;
              grpc_pass grpc://${loopback}:${toString local};
            ''
          else
            ''
              proxy_set_header ${telemetry.tenantHeader} $push_tenant;
              proxy_pass http://${loopback}:${toString local};
            ''
        );
      });
    };
in
{
  homelab.textfiles = [
    spotPriceFile
    alertsExportFile
  ];

  sops.secrets = {
    ntfy-grafana-password = { };
    telegram-bot-token = { };
    telegram-chat-id = { };
  };
  sops.templates."grafana-contact-points.yaml" = {
    owner = "grafana";
    content = builtins.toJSON contactPoints;
  };

  homelab.nasMounts = nasMountRo appImportsMount telemetry.appDashboardsShare;

  # every store on the guest's own disk, seeded from and mirrored to its nas share: a nas hang never stalls monitoring
  homelab.localState = {
    grafana = {
      path = "/var/lib/grafana";
      unit = "grafana";
      sqlite = [ "data/grafana.db" ];
    };
    prometheus = {
      path = "/var/lib/${config.services.prometheus.stateDir}";
      unit = "prometheus";
    };
    loki = {
      path = lokiDir;
      unit = "loki";
    };
    pyroscope = {
      path = pyroscopeDir;
      unit = "pyroscope";
    };
  };

  # vacuum deletes archived files only: a host that stopped uploading leaves an active file nothing ever archives
  systemd.services.journal-remote-vacuum = {
    description = "Drop received journals past their retention";
    startAt = "hourly";
    serviceConfig.Type = "oneshot";
    script = ''
      ${config.systemd.package}/bin/journalctl --directory=${journalRemoteDir} --vacuum-size=${journalRemoteMaxUse} --vacuum-time=${observabilityRetention}
      ${pkgs.findutils}/bin/find ${journalRemoteDir} -name '*.journal' -mtime +${toString observabilityRetentionDays} -delete
    '';
  };

  services.journald.remote = {
    enable = true;
    listen = "http";
    port = ports.journalRemote;
    # loki is the long-term store, this is a buffer; a file is archived, and so vacuumed, only once it reaches its size
    settings.Remote = {
      SplitMode = "host";
      MaxUse = journalRemoteMaxUse;
      MaxFileSize = journalRemoteFileSize;
    };
  };

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = true;
      server = {
        # info logs every query and table lookup, most of this guest's journal
        log_level = "warn";
        http_listen_address = loopback;
        http_listen_port = ports.lokiLocal;
        grpc_listen_address = loopback;
        grpc_listen_port = lokiGrpcPort;
      };
      querier.multi_tenant_queries_enabled = true;
      runtime_config.file = pkgs.writeText "loki-overrides.yaml" (
        builtins.toJSON {
          overrides.${telemetry.labTenant} = {
            ingestion_rate_mb = mibOf limits.lab.logBytesPerSecond;
            ingestion_burst_size_mb = mibOf limits.lab.logBurstBytes;
          };
        }
      );
      common = {
        instance_addr = loopback;
        ring.kvstore.store = "inmemory";
        replication_factor = 1;
        path_prefix = lokiDir;
      };
      schema_config.configs = [
        {
          from = "2024-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      storage_config.filesystem.directory = "${lokiDir}/chunks";
      compactor = {
        working_directory = "${lokiDir}/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      # logs drilldown's patterns tab
      pattern_ingester.enabled = true;
      limits_config = {
        retention_period = observabilityRetention;
        volume_enabled = true;
        # logs drilldown groups by service_name: a journal line by its unit, a container's by its name, the rest (the
        # ingresses' access logs, crowdsec) by job; set at ingestion, so older lines keep the job
        discover_service_name = [
          "service_name"
          "service"
          "container_name"
          "unit"
          "job"
        ];
        discover_log_levels = true;
        reject_old_samples = false;
        max_entries_limit_per_query = lokiMaxLines;
        # per tenant: an app's budget (the lab's own in the overrides); lines past the limit are cut, not dropped
        ingestion_rate_mb = mibOf (limits.tenant.logLinesPerSecond * limits.tenant.logLineBytes);
        ingestion_burst_size_mb = mibOf (limits.tenant.logBurstLines * limits.tenant.logLineBytes);
        max_line_size = limits.tenant.logLineBytes;
        max_line_size_truncate = true;
      };
    };
  };

  services.tempo = {
    enable = true;
    settings = {
      server = {
        http_listen_address = loopback;
        http_listen_port = ports.tempo;
        grpc_listen_address = loopback;
        grpc_listen_port = tempoGrpcPort;
      };
      multitenancy_enabled = true;
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "${loopback}:${toString ports.otlpGrpcLocal}";
        http.endpoint = "${loopback}:${toString ports.otlpHttpLocal}";
      };
      ingester.lifecycler.ring = {
        replication_factor = 1;
        kvstore.store = "inmemory";
      };
      storage.trace = {
        backend = "local";
        local.path = "${tempoDir}/traces";
        wal.path = "${tempoDir}/wal";
      };
      metrics_generator = {
        registry = {
          external_labels.source = "tempo";
          inject_tenant_id_as = tenantLabel;
        };
        storage = {
          path = "${tempoDir}/generator/wal";
          remote_write = [
            {
              url = "http://${loopback}:${toString ports.prometheusLocal}/api/v1/write";
              send_exemplars = true;
            }
          ];
        };
        # local-blocks backs traceql metrics queries in grafana
        traces_storage.path = "${tempoDir}/generator/traces";
        # the template's setting: client and internal spans count too, not only server spans
        processor.local_blocks.filter_server_spans = false;
      };
      overrides.defaults = {
        ingestion = {
          rate_limit_bytes = limits.tenant.traceBytesPerSecond;
          burst_size_bytes = limits.tenant.traceBurstBytes;
        };
        metrics_generator = {
          processors = [
            "service-graphs"
            "span-metrics"
            "local-blocks"
          ];
          max_active_series = tempoMaxActiveSeries;
        };
      };
    };
  };

  # browsers' otlp, relayed by the ingress with the app's tenant; allow-lists keep cookies and form fields out
  systemd.services.otel-frontend = {
    description = "OpenTelemetry intake for the apps' browsers";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib --config ${frontendIntakeConfig}";
      DynamicUser = true;
      MemoryMax = "${toString (frontendIntakeMemoryMiB * 2)}M";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  users.users.pyroscope = {
    isSystemUser = true;
    group = "pyroscope";
  };
  users.groups.pyroscope = { };
  systemd.services.pyroscope = {
    description = "Grafana Pyroscope continuous profiling";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " (
        [
          "${pkgs.pyroscope}/bin/pyroscope"
          "-server.http-listen-address=${loopback}"
          "-server.http-listen-port=${toString ports.pyroscopeLocal}"
          "-server.grpc-listen-address=${loopback}"
          "-server.grpc-listen-port=${toString pyroscopeGrpcPort}"
          "-memberlist.bind-port=${toString pyroscopeMemberlistPort}"
        ]
        ++ map (flag: "-${flag}=${loopback}") pyroscopeRings
        ++ [
          "-pyroscopedb.data-path=${pyroscopeDir}/data"
          # single binary: the compactor needs a bucket to apply the retention to
          "-storage.backend=filesystem"
          "-storage.filesystem.dir=${pyroscopeDir}/shared"
          "-compactor.data-dir=${pyroscopeDir}/compactor"
          "-blocks-storage.bucket-store.sync-dir=${pyroscopeDir}/sync"
          "-compactor.blocks-retention-period=${observabilityRetention}"
          "-usage-stats.enabled=false"
          "-auth.multitenancy-enabled=true"
          "-distributor.ingestion-rate-limit-mb=${toString (mibOf limits.tenant.profileBytesPerSecond)}"
          "-distributor.ingestion-burst-size-mb=${toString (mibOf limits.tenant.profileBurstBytes)}"
          # profiling itself would be most of what is stored
          "-self-profiling.disable-push=true"
        ]
      );
      User = "pyroscope";
      Group = "pyroscope";
      WorkingDirectory = pyroscopeDir;
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # tempo is a DynamicUser: its StateDirectory makes its own dir
  systemd.tmpfiles.rules = [
    "d ${lokiDir} 0750 loki loki -"
    "d ${pyroscopeDir} 0750 pyroscope pyroscope -"
    # its disk retention check fails on a missing data dir until the first profile arrives
    "d ${pyroscopeDir}/data 0750 pyroscope pyroscope -"
  ];

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = loopback;
    port = blackboxPort;
    configFile = pkgs.writeText "blackbox.yml" (
      builtins.toJSON {
        modules = {
          # liveness: 401/403/3xx/404 count as up, 5xx not
          http_up = {
            prober = "http";
            timeout = "10s";
            http = {
              valid_status_codes = [
                200
                201
                204
                301
                302
                303
                307
                308
                401
                403
                404
              ];
              follow_redirects = false;
              preferred_ip_protocol = "ip4";
            };
          };
          # a third party's service is up while it answers below 500 (modules/upstream)
          upstream_up = {
            prober = "http";
            timeout = "10s";
            http = {
              valid_status_codes = lib.range 100 499;
              follow_redirects = false;
              preferred_ip_protocol = "ip4";
            };
          };
          tcp_up = {
            prober = "tcp";
            timeout = "5s";
            tcp.preferred_ip_protocol = "ip4";
          };
        };
      }
    );
  };

  # the units monitoring_unit_down watches, and nothing else: every unit is a series
  services.prometheus.exporters.node = {
    enabledCollectors = [ "systemd" ];
    extraFlags = [ "--collector.systemd.unit-include=${monitoringUnitsRegex}" ];
  };

  services.prometheus = {
    enable = true;
    listenAddress = loopback;
    port = ports.prometheusLocal;
    retentionTime = prometheusRetentionTime;
    extraFlags = [
      "--storage.tsdb.retention.size=${toString prometheusRetentionGiB}GB"
      # tempo's metrics generator pushes span metrics here, over loopback
      "--web.enable-remote-write-receiver"
      # the trace ids on those span metrics, for grafana's exemplar links
      "--enable-feature=exemplar-storage"
      # the browsers' metrics, through the frontend intake, over loopback
      "--web.enable-otlp-receiver"
    ];
    scrapeConfigs = [
      {
        job_name = "prometheus";
        static_configs = [ { targets = [ "${loopback}:${toString ports.prometheusLocal}" ]; } ];
      }
      {
        job_name = "monitoring";
        static_configs =
          lib.mapAttrsToList
            (component: port: {
              targets = [ "${loopback}:${toString port}" ];
              labels = {
                inherit component;
                vm = vmName collector;
              };
            })
            {
              loki = ports.lokiLocal;
              inherit (ports) tempo promtail;
              pyroscope = ports.pyroscopeLocal;
              grafana = grafanaLocalPort;
            };
      }
      (probeJob "http")
      (probeJob "tcp")
      (probeJobOf "blackbox-backend" "tcp_up" backendProbes)
      (
        probeJob "http"
        // {
          job_name = upstreamJob;
          params.module = [ "upstream_up" ];
          static_configs = lib.mapAttrsToList (upstream: u: {
            targets = [ u.url ];
            labels = { inherit upstream; };
          }) lab.upstreams;
        }
      )
      {
        job_name = nodeJob;
        static_configs = map (t: {
          targets = [ "${t.address}:${toString net.ports.nodeExporter}" ];
          labels = {
            inherit (t) vm;
          }
          // lib.optionalAttrs t.idle { idle = "true"; };
        }) nodeTargets;
      }
      {
        job_name = "traefik";
        static_configs = [ { targets = map traefikTargetOf ingressZones; } ];
      }
    ]
    ++ ingressScrapeConfigs
    ++ lib.optional inverter {
      job_name = "fronius";
      scrape_interval = "10s";
      static_configs = [ { targets = [ froniusListen ]; } ];
    }
    ++ lib.optional homeAssistantPowered {
      job_name = "homeassistant";
      scrape_interval = "60s";
      metrics_path = "/api/prometheus";
      authorization.credentials_file = hassScrapeToken;
      static_configs = [ { targets = [ "${(guest homeAssistant.vmid).ip}:${toString homeAssistant.port}" ]; } ];
    }
    ++ exporterScrapeConfigs
    ++ appScrapeConfigs;
    # the hass token file only exists at runtime
    checkConfig = "syntax-only";
  };

  services.nginx = {
    enable = true;
    appendHttpConfig = pushTenantMap + grafanaIdentityMap;
    virtualHosts = {
      grafana = grafanaDoor;
      # reads only: no reader may forge a backup timestamp or a meter reading
      prometheus-read = {
        listen = [
          {
            addr = "0.0.0.0";
            port = ports.prometheus;
          }
        ];
        locations."/" = {
          proxyPass = "http://${loopback}:${toString ports.prometheusLocal}";
          # GET covers HEAD; the ui and every api read
          extraConfig = "limit_except GET { deny all; }";
        };
        # long queries are a form POST; still reads
        locations."~ ^/api/v1/(query|query_range|query_exemplars|series|labels|label/[^/]+/values)$" = {
          proxyPass = "http://${loopback}:${toString ports.prometheusLocal}";
          extraConfig = "limit_except GET POST { deny all; }";
        };
      };
      loki-read = {
        listen = [
          {
            addr = "0.0.0.0";
            port = ports.loki;
          }
        ];
        locations."/".return = "404";
        locations."/loki/api/v1/" = {
          proxyPass = "http://${loopback}:${toString ports.lokiLocal}";
          extraConfig = ''
            limit_except GET { deny all; }
            proxy_set_header ${telemetry.tenantHeader} $read_tenant;
          '';
        };
      };
      loki-push = pushDoor {
        door = "lokiPush";
        body = pushBodyBytes.loki;
        local = ports.lokiLocal;
      };
      otlp-http = pushDoor {
        door = "otlpHttp";
        body = pushBodyBytes.otlp;
        local = ports.otlpHttpLocal;
      };
      otlp-grpc = pushDoor {
        door = "otlpGrpc";
        body = pushBodyBytes.otlp;
        local = ports.otlpGrpcLocal;
        grpc = true;
      };
      pyroscope-push = pushDoor {
        door = "pyroscope";
        body = pushBodyBytes.pyroscope;
        local = ports.pyroscopeLocal;
      };
    };
  };

  systemd.services.prometheus-hass-token = lib.mkIf homeAssistantPowered {
    description = "Stage the Home Assistant token for the Prometheus scrape";
    before = [ "prometheus.service" ];
    requiredBy = [ "prometheus.service" ];
    after = [ "remote-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 750 -o prometheus -g prometheus ${builtins.dirOf hassScrapeToken}
      # empty token: the scrape answers 401 until the file shows up
      token=${config.homelab.tokens.dir}/hass-key.token
      [ -s "$token" ] || token=/dev/null
      install -m 400 -o prometheus -g prometheus "$token" ${hassScrapeToken}
    '';
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = loopback;
        http_port = grafanaLocalPort;
        root_url = grafanaRootUrl;
      };
      # gated by authelia forwardauth
      auth.disable_login_form = true;
      "auth.anonymous".enabled = false;
      # the user and the role come from the door (grafanaDoor), which takes them from the ingress and loopback alone
      "auth.proxy" = {
        enabled = true;
        header_name = grafanaUserHeader;
        header_property = "username";
        headers = "Role:${grafanaRoleHeader}";
        auto_sign_up = true;
        whitelist = loopback;
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
      };
      users = {
        allow_sign_up = false;
        auto_assign_org_role = "Viewer";
      };
      dashboards.default_home_dashboard_path = "/etc/${homelabBoardPath}";
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = tenantDatasources ++ [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://${loopback}:${toString ports.prometheusLocal}";
            uid = "prometheus";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://${loopback}:${toString ports.lokiLocal}";
            uid = "loki";
            jsonData =
              lokiJsonData
              // tenantHeader
              // {
                # an ingress's access log line names the span its traefik sent (modules/traefik tracing)
                derivedFields = [
                  {
                    name = "TraceId";
                    matcherRegex = "\"TraceId\":\"(\\w+)\"";
                    url = "$${__value.raw}";
                    datasourceUid = labTempoUid;
                  }
                ];
              };
            # the lab tenant alone: logs drilldown's detected labels and limits refuse a multi-tenant query
            secureJsonData = tenantSecureJsonOf "loki" telemetry.labTenant;
          }
          {
            name = "Loki (all tenants)";
            type = "loki";
            access = "proxy";
            url = "http://${loopback}:${toString ports.lokiLocal}";
            uid = "loki-all";
            jsonData = lokiJsonData // tenantHeader;
            secureJsonData = tenantSecureJsonOf "loki-all" lokiTenants;
          }
          # the ingresses' request spans: a lab sender's land in the lab tenant (pushTenantMap)
          {
            name = "Tempo";
            type = "tempo";
            access = "proxy";
            url = "http://${loopback}:${toString ports.tempo}";
            uid = labTempoUid;
            secureJsonData = tenantSecureJsonOf labTempoUid telemetry.labTenant;
            jsonData = tenantHeader // {
              tracesToLogsV2 = {
                datasourceUid = "loki";
                customQuery = true;
                query = "{job=\"traefik-access\"} |= \"$${__trace.traceId}\"";
                spanStartTimeShift = "-5m";
                spanEndTimeShift = "5m";
              };
              serviceMap.datasourceUid = "prometheus";
              nodeGraph.enabled = true;
            };
          }
          # profiles drilldown's source for the lab tenant
          {
            name = "Pyroscope";
            type = "grafana-pyroscope-datasource";
            access = "proxy";
            url = "http://${loopback}:${toString ports.pyroscopeLocal}";
            uid = "pyroscope";
            secureJsonData = tenantSecureJsonOf "pyroscope" telemetry.labTenant;
            jsonData = tenantHeader;
          }
        ];
      };
      dashboards.settings.providers = [
        {
          name = "Default";
          options.path = "/etc/${boardsDir}";
        }
        # one folder per app, holding its generated board and, from the share, the boards it ships
        {
          name = "Apps";
          options = {
            path = "/etc/${appBoardsDir}";
            foldersFromFilesStructure = true;
          };
        }
        {
          name = "App boards";
          updateIntervalSeconds = appImportScanS;
          options = {
            path = "${appImportsMount}/${telemetry.appDashboardsDir}";
            foldersFromFilesStructure = true;
          };
        }
      ];
      alerting = {
        contactPoints.path = config.sops.templates."grafana-contact-points.yaml".path;
        templates.settings = {
          apiVersion = 1;
          templates = [
            {
              orgId = 1;
              name = "homelab";
              template = notifications.telegramTemplate;
            }
          ];
        };
        policies.settings = {
          apiVersion = 1;
          # one message per category, re-sent at most daily while it lasts
          policies = [
            {
              orgId = 1;
              receiver = "ntfy";
              group_by = [ "category" ];
              group_wait = "1m";
              group_interval = "15m";
              repeat_interval = "24h";
              # a matching child route stops the fallback to the root receiver, so ntfy needs its own route
              routes = [
                {
                  receiver = "heartbeat";
                  object_matchers = [
                    [
                      "category"
                      "="
                      "heartbeat"
                    ]
                  ];
                  group_wait = "0s";
                  group_interval = "1m";
                  repeat_interval = "${toString ntfy.heartbeatIntervalMin}m";
                  continue = false;
                }
                {
                  receiver = "telegram";
                  object_matchers = [
                    [
                      "notify"
                      "="
                      "telegram"
                    ]
                  ];
                  continue = true;
                }
                { receiver = "ntfy"; }
              ];
            }
          ];
        };
        rules.settings = {
          apiVersion = 1;
          groups = [
            {
              orgId = 1;
              name = "homelab";
              folder = "Homelab";
              interval = "1m";
              rules = lib.mapAttrsToList ruleOf rules;
            }
          ];
        };
      };
    };
  };

  environment.etc =
    lib.mapAttrs' (name: board: lib.nameValuePair (boardPathOf name) { source = board; }) dashboards
    // lib.mapAttrs' (
      key: board: lib.nameValuePair "${appBoardsDir}/${boardFolderOf key}/service-${key}.json" { source = board; }
    ) serviceDashboards;

  # the file provider rescans only at startup
  systemd.services.grafana.restartTriggers = lib.attrValues dashboards ++ lib.attrValues serviceDashboards;

  systemd.services.spot-price = {
    description = "Export the day-ahead spot price";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = baseNameOf spotPriceState;
    };
    script = "${spotPrice}/bin/spot-price ${spotPriceState}/spot.json ${textfileDir}/${spotPriceFile}.prom";
  };

  # quarter-hour slots; the prices themselves come from the cache, fetched a few times a day
  systemd.timers.spot-price = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:00/15:05";
      Persistent = true;
    };
  };

  systemd.services.fronius-exporter = lib.mkIf inverter {
    description = "Prometheus exporter for the Fronius inverter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      FRONIUS_HOST = site.lan.inverter;
      FRONIUS_LISTEN = froniusListen;
    };
    serviceConfig = {
      ExecStart = "${froniusExporter}/bin/fronius-exporter";
      DynamicUser = true;
      Restart = "always";
      RestartSec = 10;
    };
  };

  # firing alerts as a gauge for readers without grafana access (the desktop bar); fingerprint splits equal labels
  systemd.services.grafana-alerts-export = {
    description = "Export firing Grafana alerts to Prometheus";
    after = [ "grafana.service" ];
    path = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=${textfileDir}/${alertsExportFile}.prom
      # no answer means no data, never a stale alert list
      if ! json=$(curl -sf -m10 -H '${grafanaUserHeader}: admin' \
          'http://${loopback}:${toString grafanaLocalPort}/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'); then
        rm -f "$out"; exit 0
      fi
      {
        echo "# HELP homelab_alert_firing Start time of a firing Grafana alert."
        echo "# TYPE homelab_alert_firing gauge"
        # the watchdog fires by design and is no alert
        echo "$json" | jq -r '
          def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          def summary: ${notifications.exportSummaryJq};
          .[] | select(.labels.category != "heartbeat") | "homelab_alert_firing{alertname=\"\(.labels.alertname // "alert" | esc)\",target=\"\(.labels.vm // .labels.instance // "" | esc)\",severity=\"\(.labels.severity // "" | esc)\",summary=\"\(summary | esc)\",fingerprint=\"\(.fingerprint | esc)\"} \(.startsAt | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch now | floor)"'
      } > "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
  systemd.timers.grafana-alerts-export = {
    wantedBy = [ "timers.target" ];
    # the desktop bar needs nothing fresher, and every run logs into the journal loki keeps
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  networking.firewall.allowedTCPPorts = with ports; [
    prometheus
    loki
    lokiPush
    otlpGrpc
    otlpHttp
    pyroscope
    journalRemote
    otlpFrontend
  ];
  # the query doors read every tenant: the grants only (grafana's own port is its route's). The push doors are open
  # to whoever the router lets through; their tenant map decides what a sender may write
  homelab.ingressOnly.ports = with ports; [
    prometheus
    loki
    otlpFrontend
  ];

  # tsdb and loki read their hot blocks from the page cache
  homelab.dropCaches = false;
}
