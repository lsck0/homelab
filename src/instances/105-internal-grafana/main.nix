# observability: prometheus, loki, tempo and pyroscope behind their doors, grafana with the lab's boards and alerts
#
# Doors: senders reach nginx, never a store. A push door takes one path per signal and sets the tenant from the
# sender's address: every lab host writes the lab's, an app node only the tenants of the apps its cluster runs (its
# relay names them, modules/app-telemetry.nix). The query doors serve reads to their grants only. The stores listen on
# loopback, where grafana, the alert rules and the frontend intake reach them.
{ config, pkgs, lib, inventory, nasMountRo, site, catalog, lab, ... }:
let
  telemetry = import ../../modules/telemetry.nix { inherit lib inventory; };
  net = import ../../modules/net.nix { inherit lib inventory site; };
  limits = import ../../modules/limits { inherit lib; };
  ntfy = import ../../modules/ntfy.nix;
  inherit (telemetry) vmName ports;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  tempoGrpcPort = 9095;
  lokiGrpcPort = 9096;
  pyroscopeGrpcPort = 9097;
  # tempo's memberlist default is 7946; nothing joins this ring, it only must not collide
  pyroscopeMemberlistPort = 7947;
  blackboxPort = 9115;
  froniusListen = "127.0.0.1:9118";
  loopback = "127.0.0.1";

  # the single binary dials its own components at the address its rings advertise, eth0 by default; loopback keeps
  # them, and the gossip, on the host
  pyroscopeRings = [
    "compactor.ring.instance-addr" "distributor.ring.instance-addr" "overrides-exporter.ring.instance-addr"
    "query-frontend.instance-addr" "query-scheduler.ring.instance-addr" "store-gateway.sharding-ring.instance-addr"
    "ingester.lifecycler.addr" "memberlist.advertise-addr" "memberlist.bind-addr"
  ];
  pyroscopeDir = "/var/lib/pyroscope";
  lokiDir = "/var/lib/loki";
  tempoDir = "/var/lib/tempo";

  # logs and profiles are kept as long: a profile never outlives the logs around it
  observabilityRetention = "336h";
  # loki's default 5000 cut the template's log panels short
  lokiMaxLines = 10000;
  # the template's datasource timeout: 7d and 30d unique-visitor queries parse every access log line
  lokiQueryTimeoutSeconds = 60;
  # the span metrics' cardinality is bounded here: any lab guest may send spans, and a span name is a label
  tempoMaxActiveSeries = 20000;
  # loki and pyroscope count their budgets in MiB, fractions allowed
  mibOf = bytes: bytes / (1024.0 * 1024);
  # tempo labels its span metrics with the tenant, so a board and an alert find an app's spans
  tenantLabel = "tenant";

  prometheusRetentionTime = "10y";
  # energy history is the long-lived data, ~1GB a month: the size, not the 10y, ends it. The local disk
  # (instance.nix diskGiB) also holds the system, journal-remote's 1G and loki's two weeks
  nonPrometheusGiB = 24;
  # the cap the store had on the nas: a smaller one would delete its oldest months at the first start
  prometheusRetentionFloorGiB = 50;
  prometheusRetentionGiB = let gib = lab.instances.${telemetry.collectorVmid}.config.vm.diskGiB - nonPrometheusGiB; in
    assert lib.assertMsg (gib >= prometheusRetentionFloorGiB)
      "105: diskGiB leaves prometheus ${toString gib}GB, below the ${toString prometheusRetentionFloorGiB}GB its history needs";
    gib;

  # the template's dashboards rate over [1m], four samples at 15s; the lab default of 1m leaves one
  appScrapeInterval = "15s";
  nodeJob = "homelab-node-exporter";
  cadvisorJob = "app-cadvisor";
  proxmoxVm = "proxmox";

  # the units monitoring_unit_down watches; node-exporter's systemd collector reports exactly these
  monitoringUnits = [
    "grafana" "prometheus" "nginx" "loki" "tempo" "pyroscope" "promtail" "systemd-journal-remote"
    "prometheus-blackbox-exporter"
  ];
  # [.]: a literal dot that needs no backslash, which systemd's ExecStart and a promql string would each unescape
  monitoringUnitsRegex = "(${lib.concatStringsSep "|" monitoringUnits})[.]service";

  # each push door's body cap: the largest burst its store admits from one tenant
  pushBodyBytes = {
    loki = lib.max limits.lab.logBurstBytes (limits.tenant.logBurstLines * limits.tenant.logLineBytes);
    otlp = limits.tenant.traceBurstBytes;
    pyroscope = limits.tenant.profileBurstBytes;
  };
  # tempo's otlp/grpc trace service, the only rpc the grpc door passes
  otlpGrpcExport = "/opentelemetry.proto.collector.trace.v1.TraceService/Export";

  # the browser attributes kept: a route and a status explain a slow or failed request, the rest could be a person
  frontendSpanAttributes = [
    "http.request.method" "http.response.status_code" "http.route" "url.path" "server.address" "error.type"
    "exception.type" "component"
  ];
  frontendResourceAttributes = [
    "service.name" "service.version" "deployment.environment.name" "telemetry.sdk.name" "telemetry.sdk.language"
    "telemetry.sdk.version" "browser.platform" "browser.mobile"
  ];
  # the README's snippet: web vitals as one histogram told apart by name
  frontendMetricAttributes = [ "web_vital.name" ];
  frontendIntakeMemoryMiB = 128;

  # ntfy renders go templates on the webhook body; one message per category (the grouping below)
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL "{{if eq .status \"firing\"}}FIRING{{else}}RESOLVED{{end}}: {{if eq .status \"firing\"}}{{.commonAnnotations.firing}}{{else}}{{.commonAnnotations.resolved}}{{end}}"}"
    "message=${lib.escapeURL "{{range .alerts}}{{if .annotations.summary}}{{.annotations.summary}}{{else}}{{.labels.alertname}}{{end}}\n{{end}}"}"
    "tags=${lib.escapeURL "rotating_light"}"
  ];
  ntfyHeartbeatQuery = "template=yes&message=${lib.escapeURL "vm-105 alerting alive, {{.status}}"}";
  # html-escaped: telegram rejects a whole message with 400 over one unescaped "<id>"
  telegramMessage = ''
    {{ if .Alerts.Firing }}🔴 <b>{{ .CommonAnnotations.firing | html }}</b>
    {{ range .Alerts.Firing }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}{{ if .Alerts.Resolved }}✅ <b>{{ .CommonAnnotations.resolved | html }}</b>
    {{ range .Alerts.Resolved }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}'';

  # each app's folder: its generated board here, the boards it ships on the share the deploy controller writes
  appBoardsDir = "grafana-apps";
  appImportsMount = "/var/lib/app-dashboards";
  appImportScanS = 60;

  # -----------------------------------------------------------------------------
  # GUESTS
  # -----------------------------------------------------------------------------

  guest = vmid: inventory.${toString vmid} or (throw "105-internal-grafana: the inventory has no guest ${toString vmid}");
  guestAt = ip: lib.findFirst (v: v.ip == ip) (throw "105-internal-grafana: the inventory has no guest at ${ip}") (lib.attrValues inventory);
  ingressOf = zone: guest net.zones.${zone}.ingress;
  collector = guest telemetry.collectorVmid;
  router = lib.findFirst (v: v.type == "router") null (lib.attrValues inventory);
  # the router as this host reaches it: its leg in the internal zone, this host's gateway
  routerAddress = collector.gateway;
  # powered and never asleep: a probe or an alert on anything else would wake it or alarm while it sleeps
  awake = v: v.powered && v.idle == null;

  # every node app tasks run on: the shared swarm's workers and each guest-placed app's own guest (its swarm of one)
  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  appNodes = map guest (lib.sort (a: b: lib.toInt a < lib.toInt b) appNodeIds);

  # the push doors' senders: an app node may name the tenant of each app its cluster runs, a lab host writes the lab's
  appSenders = lib.concatLists (lib.mapAttrsToList (_: c: lib.concatMap (id:
    map (app: { inherit ((guest id)) ip; tenant = telemetry.tenantOf app; }) (lib.attrNames c.apps)) c.workerIds)
    (lib.filterAttrs (_: c: lib.any telemetry.sendsSignals (lib.attrValues c.apps)) catalog.clusters));
  labSenders = [ loopback ] ++ map (v: v.ip)
    (lib.attrValues (lib.filterAttrs (id: v: v.type != "router" && !(lib.elem id appNodeIds)) inventory));

  # -----------------------------------------------------------------------------
  # SCRAPES
  # -----------------------------------------------------------------------------

  # a powered-off guest is not scraped; an idle one is, labeled, so the offline alert knows it sleeps on purpose
  nodeTargets = lib.mapAttrsToList (_: v: { address = v.ip; vm = vmName v; idle = v.idle != null; })
    (lib.filterAttrs (_: v: v.type != "router" && v.powered) inventory)
    ++ lib.optional (router != null) { address = routerAddress; vm = vmName router; idle = false; }
    ++ [ { address = site.lan.proxmox; vm = proxmoxVm; idle = false; } ];
  guestsExpectedUp = "up{job=\"${nodeJob}\",idle=\"\"}";

  # a guest that is off on purpose has nothing to scrape, draw or alert on
  services = lib.filterAttrs (_: s: s.vmid == null || (guest s.vmid).powered) catalog.services;
  servicesOn = feature: lib.filterAttrs (_: s: s.on.${feature}) services;
  isApp = s: s.app != null;
  exportersOf = s: if s.on.metrics then s.metrics else { };
  # an app's exporter answers on any node of its cluster's routing mesh (one, or each sample counts once per node)
  exporterNodeOf = s: if isApp s then guestAt (lib.head s.cluster.nodes) else guest s.vmid;
  exporterJobOf = key: s: name: "${if isApp s then "app" else "service"}-${key}-${name}";
  # each exporter in its own job: one above its budget fails its own scrape, nobody else's
  exporterScrapeConfigs = lib.concatLists (lib.mapAttrsToList (key: s: lib.mapAttrsToList (name: m: {
    job_name = exporterJobOf key s name;
    scrape_interval = appScrapeInterval;
    metrics_path = m.path;
    sample_limit = limits.tenant.scrapeSamples;
    static_configs = [{
      targets = [ "${(exporterNodeOf s).ip}:${toString m.port}" ];
      labels = { ${if isApp s then "app" else "service"} = key; vm = vmName (exporterNodeOf s); };
    }];
  }) (exportersOf s)) services);

  appScrapeConfigs = lib.optionals (catalog.apps != { }) [
    {
      # per node: each cadvisor sees only its own node's containers
      job_name = cadvisorJob;
      scrape_interval = appScrapeInterval;
      static_configs = map (node: { targets = [ "${node.ip}:${toString catalog.swarm.cadvisorPort}" ]; labels.vm = vmName node; }) appNodes;
      metric_relabel_configs = [
        # every systemd slice is a cgroup too; only containers carry a name, the rest is cardinality
        { source_labels = [ "__name__" "name" ]; regex = "container_.*;"; action = "drop"; }
        { source_labels = [ "name" ]; regex = telemetry.swarmTaskPatterns.service; target_label = "swarm_service"; }
        { source_labels = [ "name" ]; regex = telemetry.swarmTaskPatterns.stack; target_label = "swarm_stack"; }
      ];
    }
    {
      # each node's log shipper: what it dropped per app above the app's budget (modules/app-telemetry.nix)
      job_name = config.homelab.appTelemetry.shipperJob;
      scrape_interval = appScrapeInterval;
      static_configs = map (node: { targets = [ "${node.ip}:${toString ports.promtail}" ]; labels.vm = vmName node; }) appNodes;
    }
  ];

  traefikTargetOf = zone: "${(ingressOf zone).ip}:${toString net.ports.traefikMetrics}";

  # -----------------------------------------------------------------------------
  # PROBES
  # -----------------------------------------------------------------------------

  # a nixos service's route as a visitor reaches it, through its zone's ingress, which answers its health path
  httpProbes = lib.mapAttrsToList (name: r: {
    inherit name;
    vm = vmName (guest r.vmid);
    target = catalog.probeUrlOf r;
  }) (lib.filterAttrs (_: r: r.vmid != null && r.off.probe == null && awake (guest r.vmid)) (catalog.internal // catalog.external));
  # a tcp route at the backend the router forwards to; udp has no generic probe
  tcpProbes = lib.mapAttrsToList (name: r: let node = if r.vmid != null then guest r.vmid else guestAt (lib.head r.nodes); in {
    inherit name;
    vm = vmName node;
    target = "${node.ip}:${toString r.port}";
  }) (lib.filterAttrs (_: r: r.protocol == "tcp" && r.off.probe == null && (r.vmid == null || awake (guest r.vmid))) catalog.l4);
  # what an instance probes besides its routes (instance.nix `probes`), at its own address
  instanceProbes = lib.mapAttrsToList (name: p: {
    inherit name;
    inherit (p) protocol;
    vm = vmName (guest p.vmid);
    target = if p.protocol == "http" then "http://${(guest p.vmid).ip}:${toString p.port}${p.path}" else "${(guest p.vmid).ip}:${toString p.port}";
  }) (lib.filterAttrs (_: p: awake (guest p.vmid)) lab.probes);
  probesOf = protocol: lib.filter (p: p.protocol == protocol) instanceProbes ++ (if protocol == "http" then httpProbes else tcpProbes);
  probeJob = protocol: {
    job_name = "blackbox-${protocol}";
    metrics_path = "/probe";
    params.module = [ "${protocol}_up" ];
    scrape_interval = "60s";
    static_configs = map (p: { targets = [ p.target ]; labels = { service = p.name; inherit (p) vm; }; }) (probesOf protocol);
    relabel_configs = [
      { source_labels = [ "__address__" ]; target_label = "__param_target"; }
      { source_labels = [ "__param_target" ]; target_label = "instance"; }
      { target_label = "__address__"; replacement = "${loopback}:${toString blackboxPort}"; }
    ];
  };

  # -----------------------------------------------------------------------------
  # ALERTING
  # -----------------------------------------------------------------------------

  labRules = telemetry.alertsOf (import ./lib/rules.nix {
    inherit lib telemetry ntfy catalog nodeJob guestsExpectedUp monitoringUnitsRegex services exportersOf exporterJobOf;
    edgeTraefikTarget = traefikTargetOf "external";
  });
  # the rules instances and apps declare over their own metrics; an app's uid carries the app
  ownRules = lib.mapAttrs (_: a: removeAttrs a [ "vmid" ]) lab.alerts
    // lib.concatMapAttrs (app: a: lib.mapAttrs' (name: lib.nameValuePair "app_${app}_${name}") a.alerts) catalog.apps;
  rulesTwice = lib.intersectLists (lib.attrNames labRules) (lib.attrNames ownRules);
  rules = assert lib.assertMsg (rulesTwice == [ ]) "105-internal-grafana: alert uids declared twice: ${toString rulesTwice}";
    labRules // ownRules;

  # one Grafana-managed rule, query A thresholded by C; a rule that cannot evaluate shows health "error", which
  # tests/monitoring.nix holds at none
  ruleOf = uid: r: {
    inherit uid;
    inherit (r) title for;
    condition = "C";
    data = [
      {
        refId = "A";
        relativeTimeRange = { from = r.rangeSeconds; to = 0; };
        datasourceUid = r.datasource;
        model = { refId = "A"; inherit (r) expr; instant = true; } // lib.optionalAttrs (r.datasource == "loki") { queryType = "instant"; };
      }
      {
        refId = "C";
        datasourceUid = "__expr__";
        model = { refId = "C"; type = "threshold"; expression = "A"; conditions = [{ evaluator = { type = r.op; params = [ r.threshold ]; }; }]; };
      }
    ];
    noDataState = r.noData;
    execErrState = r.execErr;
    labels = { inherit (r) severity category; } // lib.optionalAttrs r.telegram { notify = "telegram"; };
    annotations = { inherit (r) summary description; } // telemetry.categories.${r.category};
  };

  # straight to ntfy's own port on vm-203: an edge fault must not swallow the alerts (instance.nix grant there)
  ntfyRoute = catalog.external.ntfy;
  ntfyBase = "http://${(guest ntfyRoute.vmid).ip}:${toString ntfyRoute.port}";
  ntfyReceiver = uid: topic: query: {
    inherit uid;
    type = "webhook";
    settings = {
      url = "${ntfyBase}/${topic}?${query}";
      httpMethod = "POST";
      # ntfy denies anonymous publishing
      username = "grafana";
      password = config.sops.placeholder.ntfy-grafana-password;
    };
  };
  contactPoints = {
    apiVersion = 1;
    contactPoints = [
      { orgId = 1; name = "ntfy"; receivers = [ (ntfyReceiver "ntfy_cp" ntfy.topics.alerts ntfyQuery // { disableResolveMessage = false; }) ]; }
      # silence is the signal; a resolve message would be one more heartbeat
      { orgId = 1; name = "heartbeat"; receivers = [ (ntfyReceiver "heartbeat_cp" ntfy.topics.heartbeat ntfyHeartbeatQuery // { disableResolveMessage = true; }) ]; }
      {
        orgId = 1;
        name = "telegram";
        receivers = [{
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
        }];
      }
    ];
  };

  # -----------------------------------------------------------------------------
  # BOARDS AND DATASOURCES
  # -----------------------------------------------------------------------------

  energyModel = import ../../modules/energy { inherit pkgs; };
  feedIo = import ../../modules/feeds { inherit pkgs; };
  python = name: libraries: file: pkgs.writers.writePython3Bin name {
    inherit libraries;
    flakeIgnore = [ "E501" ];
  } (builtins.readFile file);

  # inverter solar api, polled per scrape; a site without a fronius inverter (site.json) has no house power data
  froniusExporter = python "fronius-exporter" [ ] ./lib/fronius-exporter.py;
  inverter = site.lan.inverter != "";
  # local copy: a missing nas token must fail one scrape, not prometheus
  hassScrapeToken = "/run/prometheus-hass/token";
  homeAssistant = catalog.internal.homeassistant;

  spotPrice = python "spot-price" [ energyModel feedIo ] ./lib/spot-price.py;
  spotPriceState = "/var/lib/spot-price";
  inherit (config.homelab) textfileDir;
  spotPriceFile = "spot_price";
  alertsExportFile = "grafana_alerts";

  # generated, so a board cannot drift from the queries it shares (energy_model, the alert expressions)
  dashboardPython = pkgs.python3.withPackages (_: [ energyModel ]);
  dashboard = name: script: config: pkgs.runCommand "${name}.json" {
    config = builtins.toJSON config;
    passAsFile = [ "config" ];
  } ''
    PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${script} "$configPath" $out
  '';
  # the public ingress; its promtail labels the access log with this host
  edgeHost = "vm-${net.zones.external.ingress}";
  homelabDashboard = dashboard "homelab" ./lib/dashboards/homelab.py {
    uid = telemetry.homelabDashboardUid;
    inherit nodeJob guestsExpectedUp edgeHost;
    ssoHost = "vm-${toString lab.routes.authelia.vmid}";
    nasVm = vmName (guest lab.routes.nas.vmid);
    hostVm = proxmoxVm;
  };
  # energy.py takes no config, every query is energy_model's
  energyDashboard = pkgs.runCommand "energy.json" { } ''
    PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${./lib/dashboards/energy.py} $out
  '';
  # a zone's routes as the board reads them: by traefik name, access log host and metrics instance
  boardRoutes = zone: routes: lib.mapAttrsToList (name: r: {
    inherit name;
    host = net.fqdn r.host;
    ingress = "vm-${net.zones.${zone}.ingress}";
    instance = traefikTargetOf zone;
  }) routes;
  lokiJsonData = { maxLines = lokiMaxLines; timeout = lokiQueryTimeoutSeconds; };
  tenantHeader = { httpHeaderName1 = telemetry.tenantHeader; };
  # every app tenant, for the admin's view of all lines
  lokiTenants = lib.concatStringsSep "|" ([ telemetry.labTenant ] ++ map telemetry.tenantOf (lib.attrNames catalog.apps));
  # each app reads its own tenant: its logs, and with telemetry its traces (linked into its logs) and profiles
  tenantDatasources = lib.concatLists (lib.mapAttrsToList (app: a: let
    tenant = { httpHeaderValue1 = telemetry.tenantOf app; };
  in [
    {
      name = "Loki ${app}";
      type = "loki";
      access = "proxy";
      url = "http://${loopback}:${toString ports.lokiLocal}";
      uid = "loki-${app}";
      secureJsonData = tenant;
      jsonData = lokiJsonData // tenantHeader;
    }
  ] ++ lib.optional (a.off.traces == null) {
    name = "Tempo ${app}";
    type = "tempo";
    access = "proxy";
    url = "http://${loopback}:${toString ports.tempo}";
    uid = "tempo-${app}";
    secureJsonData = tenant;
    jsonData = tenantHeader // {
      # span attributes onto the labels the log pipelines set; a span carries only some of them
      tracesToLogsV2 = {
        datasourceUid = "loki-${app}";
        tags = [
          { key = "host.name"; value = "host"; }
          { key = "container.name"; value = "container_name"; }
          # no semconv names a unit: a lab service that wants the link sets this attribute
          { key = "systemd.unit"; value = "unit"; }
        ];
        # batch exporters send a span seconds after its log lines
        spanStartTimeShift = "-5m";
        spanEndTimeShift = "5m";
      };
      serviceMap.datasourceUid = "prometheus";
      nodeGraph.enabled = true;
    };
  } ++ lib.optional (a.off.profiles == null) {
    name = "Pyroscope ${app}";
    type = "grafana-pyroscope-datasource";
    access = "proxy";
    url = "http://${loopback}:${toString ports.pyroscopeLocal}";
    uid = "pyroscope-${app}";
    secureJsonData = tenant;
    jsonData = tenantHeader;
  }) catalog.apps);

  keepKeys = keys: [ "keep_keys(attributes, [${lib.concatMapStringsSep ", " builtins.toJSON keys}])" ];
  frontendIntakeConfig = pkgs.writeText "otel-frontend.json" (builtins.toJSON {
    # the paths the browsers post to on their app's origin, which the ingress passes on unchanged
    receivers.otlp.protocols.http = {
      endpoint = "0.0.0.0:${toString ports.otlpFrontend}";
      traces_url_path = "${telemetry.frontendPath}/v1/traces";
      logs_url_path = "${telemetry.frontendPath}/v1/logs";
      metrics_url_path = "${telemetry.frontendPath}/v1/metrics";
      include_metadata = true;
      max_request_body_size = limits.frontend.bodyBytes;
    };
    processors = {
      memory_limiter = { check_interval = "1s"; limit_mib = frontendIntakeMemoryMiB; spike_limit_mib = frontendIntakeMemoryMiB / 4; };
      # metrics have no tenant downstream: the app becomes a label
      "attributes/tenant".actions = [{ key = tenantLabel; from_context = "metadata.x-scope-orgid"; action = "upsert"; }];
      "transform/allow" = {
        error_mode = "ignore";
        trace_statements = [
          { context = "resource"; statements = keepKeys frontendResourceAttributes; }
          { context = "span"; statements = keepKeys frontendSpanAttributes; }
        ];
        log_statements = [
          { context = "resource"; statements = keepKeys frontendResourceAttributes; }
          { context = "log"; statements = keepKeys frontendSpanAttributes; }
        ];
        metric_statements = [
          { context = "resource"; statements = keepKeys frontendResourceAttributes; }
          { context = "datapoint"; statements = keepKeys (frontendSpanAttributes ++ frontendMetricAttributes ++ [ tenantLabel ]); }
        ];
      };
      # one batch per tenant, so the header goes out with the right one
      batch.metadata_keys = [ "x-scope-orgid" ];
    };
    extensions.headers_setter.headers = [{ key = telemetry.tenantHeader; from_context = "x-scope-orgid"; action = "upsert"; }];
    exporters = {
      "otlphttp/tempo" = { endpoint = "http://${loopback}:${toString ports.otlpHttpLocal}"; auth.authenticator = "headers_setter"; };
      "otlphttp/loki" = { endpoint = "http://${loopback}:${toString ports.lokiLocal}/otlp"; auth.authenticator = "headers_setter"; };
      "otlphttp/prometheus".endpoint = "http://${loopback}:${toString ports.prometheusLocal}/api/v1/otlp";
    };
    service = {
      extensions = [ "headers_setter" ];
      pipelines = let common = [ "memory_limiter" "transform/allow" "batch" ]; in {
        traces = { receivers = [ "otlp" ]; processors = common; exporters = [ "otlphttp/tempo" ]; };
        logs = { receivers = [ "otlp" ]; processors = common; exporters = [ "otlphttp/loki" ]; };
        metrics = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "attributes/tenant" "transform/allow" "batch" ];
          exporters = [ "otlphttp/prometheus" ];
        };
      };
    };
  });

  # one board per service, whatever it exports, and the overview of them all (lib/dashboards/service.py)
  serviceBoards = lib.mapAttrs (key: s: let
    app = isApp s;
    routesIn = routes: lib.filterAttrs (name: _: lib.elem name s.routes) routes;
  in {
    name = key;
    routes = boardRoutes "internal" (routesIn catalog.internal) ++ boardRoutes "external" (routesIn catalog.external);
    forwards = if routesIn catalog.l4 == { } || router == null then null else {
      host = router.name;
      loki = "loki";
      routes = lib.mapAttrsToList (name: r: { inherit name; inherit (r) protocol; port = r.publicPort; }) (routesIn catalog.l4);
    };
    deploys = app;
    idle = app && s.idle.stopAfter != null;
    containers = if app then "swarm_stack=\"${key}\"" else null;
    vm = if app then null else vmName (guest s.vmid);
    reservation = if app then catalog.apps.${key}.reservation else null;
    # a guest's journal holds all of its services' lines, under its hostname
    logs = if !s.on.logs then null else if app then "swarm_stack=\"${key}\"" else "host=\"vm-${toString s.vmid}\"";
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
    shipperJob = config.homelab.appTelemetry.shipperJob;
    rateWindow = "5m";
  }) (servicesOn "dashboard");
  serviceDashboards = lib.mapAttrs (name: board: dashboard name ./lib/dashboards/service.py board) serviceBoards;
  overviewDashboard = dashboard "services" ./lib/dashboards/service.py { services = lib.attrValues serviceBoards; };
  # the lab's own services share one folder; its name is no valid app name, so no app's folder can take it
  boardFolderOf = key: if isApp services.${key} then key else "Lab services";
  dashboards = { homelab = homelabDashboard; energy = energyDashboard; services = overviewDashboard; };

  # -----------------------------------------------------------------------------
  # DOORS
  # -----------------------------------------------------------------------------

  pushTenantMap = ''
    map "$remote_addr $http_x_scope_orgid" $push_tenant {
      default "";
    ${lib.concatMapStrings (s: "  \"${s.ip} ${s.tenant}\" ${s.tenant};\n") appSenders
    }  "~^(${lib.concatMapStringsSep "|" (lib.replaceStrings [ "." ] [ "\\." ]) labSenders}) " ${telemetry.labTenant};
    }
    map $http_x_scope_orgid $read_tenant { "" ${telemetry.labTenant}; default $http_x_scope_orgid; }
  '';
  # one door per signal: its paths to the store on loopback, with the sender's tenant; anything else 404s
  pushDoor = { port, body, local, paths, grpc ? false }: {
    listen = [{ addr = "0.0.0.0"; inherit port; }];
    # grpc is http/2; in clear text nginx takes it by prior knowledge, which is what grpc clients send
    extraConfig = "client_max_body_size ${toString body};" + lib.optionalString grpc "\nhttp2 on;";
    locations = { "/".return = "404"; } // lib.genAttrs (map (path: "= ${path}") paths) (_: {
      extraConfig = ''
        limit_except POST { deny all; }
        if ($push_tenant = "") { return 403; }
      '' + (if grpc then ''
        grpc_set_header ${telemetry.tenantHeader} $push_tenant;
        grpc_pass grpc://${loopback}:${toString local};
      '' else ''
        proxy_set_header ${telemetry.tenantHeader} $push_tenant;
        proxy_pass http://${loopback}:${toString local};
      '');
    });
  };
in {
  homelab.textfiles = [ spotPriceFile alertsExportFile ];

  sops.secrets = { ntfy-grafana-password = { }; telegram-bot-token = { }; telegram-chat-id = { }; };
  sops.templates."grafana-contact-points.yaml" = {
    owner = "grafana";
    content = builtins.toJSON contactPoints;
  };

  homelab.nasMounts = nasMountRo appImportsMount telemetry.appDashboardsShare;

  # every store on the guest's own disk, seeded from and mirrored to its nas share: a nas hang never stalls monitoring
  homelab.localState = {
    grafana = { path = "/var/lib/grafana"; unit = "grafana"; sqlite = [ "data/grafana.db" ]; };
    prometheus = { path = "/var/lib/${config.services.prometheus.stateDir}"; unit = "prometheus"; };
    loki = { path = lokiDir; unit = "loki"; };
    pyroscope = { path = pyroscopeDir; unit = "pyroscope"; };
  };

  # journal-remote ignores MaxUse for the journals every host uploads here, so they outgrew the disk
  systemd.services.journal-remote-vacuum = {
    description = "Cap received journals at 1G";
    startAt = "hourly";
    serviceConfig.Type = "oneshot";
    script = "${config.systemd.package}/bin/journalctl --directory=/var/log/journal/remote --vacuum-size=1G";
  };

  services.journald.remote = {
    enable = true;
    listen = "http";
    port = ports.journalRemote;
    # loki is the long-term store, this is a buffer
    settings.Remote = { SplitMode = "host"; MaxUse = "1G"; };
  };

  services.loki = {
    enable = true;
    configuration = {
      # each app is its own tenant, the lab another; the doors say which
      auth_enabled = true;
      server = {
        http_listen_address = loopback;
        http_listen_port = ports.lokiLocal;
        grpc_listen_address = loopback;
        grpc_listen_port = lokiGrpcPort;
      };
      querier.multi_tenant_queries_enabled = true;
      runtime_config.file = pkgs.writeText "loki-overrides.yaml" (builtins.toJSON {
        overrides.${telemetry.labTenant} = {
          ingestion_rate_mb = mibOf limits.lab.logBytesPerSecond;
          ingestion_burst_size_mb = mibOf limits.lab.logBurstBytes;
        };
      });
      common = {
        instance_addr = loopback;
        ring.kvstore.store = "inmemory";
        replication_factor = 1;
        path_prefix = lokiDir;
      };
      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = { prefix = "index_"; period = "24h"; };
      }];
      storage_config.filesystem.directory = "${lokiDir}/chunks";
      compactor = {
        working_directory = "${lokiDir}/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config = {
        retention_period = observabilityRetention;
        volume_enabled = true;
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
      ingester.lifecycler.ring = { replication_factor = 1; kvstore.store = "inmemory"; };
      storage.trace = {
        backend = "local";
        local.path = "${tempoDir}/traces";
        wal.path = "${tempoDir}/wal";
      };
      # rate, errors and duration per span plus the service graph, as prometheus series with trace exemplars
      metrics_generator = {
        registry = { external_labels.source = "tempo"; inject_tenant_id_as = tenantLabel; };
        storage = {
          path = "${tempoDir}/generator/wal";
          remote_write = [{ url = "http://${loopback}:${toString ports.prometheusLocal}/api/v1/write"; send_exemplars = true; }];
        };
        # local-blocks backs traceql metrics queries in grafana
        traces_storage.path = "${tempoDir}/generator/traces";
        # the template's setting: client and internal spans count too, not only server spans
        processor.local_blocks.filter_server_spans = false;
      };
      # per tenant: every tenant gets the lab's one budget (modules/limits)
      overrides.defaults = {
        ingestion = { rate_limit_bytes = limits.tenant.traceBytesPerSecond; burst_size_bytes = limits.tenant.traceBurstBytes; };
        metrics_generator = {
          processors = [ "service-graphs" "span-metrics" "local-blocks" ];
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

  users.users.pyroscope = { isSystemUser = true; group = "pyroscope"; };
  users.groups.pyroscope = { };
  systemd.services.pyroscope = {
    description = "Grafana Pyroscope continuous profiling";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " ([
        "${pkgs.pyroscope}/bin/pyroscope"
        "-server.http-listen-address=${loopback}"
        "-server.http-listen-port=${toString ports.pyroscopeLocal}"
        "-server.grpc-listen-address=${loopback}"
        "-server.grpc-listen-port=${toString pyroscopeGrpcPort}"
        "-memberlist.bind-port=${toString pyroscopeMemberlistPort}"
      ] ++ map (flag: "-${flag}=${loopback}") pyroscopeRings ++ [
        "-pyroscopedb.data-path=${pyroscopeDir}/data"
        # single binary: the compactor needs a bucket to apply the retention to
        "-storage.backend=filesystem"
        "-storage.filesystem.dir=${pyroscopeDir}/shared"
        "-compactor.data-dir=${pyroscopeDir}/compactor"
        "-blocks-storage.bucket-store.sync-dir=${pyroscopeDir}/sync"
        "-compactor.blocks-retention-period=${observabilityRetention}"
        "-usage-stats.enabled=false"
        # each app is its own tenant, every tenant gets the lab's one budget (modules/limits)
        "-auth.multitenancy-enabled=true"
        "-distributor.ingestion-rate-limit-mb=${toString (mibOf limits.tenant.profileBytesPerSecond)}"
        "-distributor.ingestion-burst-size-mb=${toString (mibOf limits.tenant.profileBurstBytes)}"
        # profiling itself would be most of what is stored
        "-self-profiling.disable-push=true"
      ]);
      User = "pyroscope";
      Group = "pyroscope";
      WorkingDirectory = pyroscopeDir;
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${tempoDir} 0750 tempo tempo -"
    "d ${lokiDir} 0750 loki loki -"
    "d ${pyroscopeDir} 0750 pyroscope pyroscope -"
    # its disk retention check fails on a missing data dir until the first profile arrives
    "d ${pyroscopeDir}/data 0750 pyroscope pyroscope -"
  ];

  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = loopback;
    port = blackboxPort;
    configFile = pkgs.writeText "blackbox.yml" (builtins.toJSON {
      modules = {
        # liveness: 401/403/3xx/404 count as up, 5xx not
        http_up = {
          prober = "http";
          timeout = "10s";
          http = {
            valid_status_codes = [ 200 201 204 301 302 303 307 308 401 403 404 ];
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
    });
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
        # tsdb size and block bytes, for the retention size cap; the watchdog's signal
        job_name = "prometheus";
        static_configs = [{ targets = [ "${loopback}:${toString ports.prometheusLocal}" ]; }];
      }
      {
        # the monitoring stack's own health: ingestion, drops, rings
        job_name = "monitoring";
        static_configs = lib.mapAttrsToList (component: port: {
          targets = [ "${loopback}:${toString port}" ];
          labels = { inherit component; vm = vmName collector; };
        }) { loki = ports.lokiLocal; tempo = ports.tempo; pyroscope = ports.pyroscopeLocal; grafana = ports.grafana; promtail = ports.promtail; };
      }
      (probeJob "http")
      (probeJob "tcp")
      {
        job_name = nodeJob;
        static_configs = map (t: {
          targets = [ "${t.address}:${toString net.ports.nodeExporter}" ];
          labels = { inherit (t) vm; } // lib.optionalAttrs t.idle { idle = "true"; };
        }) nodeTargets;
      }
      {
        job_name = "traefik";
        static_configs = [{ targets = [ (traefikTargetOf "internal") (traefikTargetOf "external") ]; }];
      }
    ] ++ lib.optional inverter {
      # house power: pv, grid meter, battery
      job_name = "fronius";
      scrape_interval = "10s";
      static_configs = [{ targets = [ froniusListen ]; }];
    } ++ [
      {
        # gas and water readings typed in by hand, the tariffs
        job_name = "homeassistant";
        scrape_interval = "60s";
        metrics_path = "/api/prometheus";
        authorization.credentials_file = hassScrapeToken;
        static_configs = [{ targets = [ "${(guest homeAssistant.vmid).ip}:${toString homeAssistant.port}" ]; }];
      }
    ] ++ exporterScrapeConfigs ++ appScrapeConfigs;
    # the hass token file only exists at runtime
    checkConfig = "syntax-only";
  };

  services.nginx = {
    enable = true;
    appendHttpConfig = pushTenantMap;
    virtualHosts = {
      # reads only: no reader may forge a backup timestamp or a meter reading
      prometheus-read = {
        listen = [{ addr = "0.0.0.0"; port = ports.prometheus; }];
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
      # a reader that names no tenant reads the lab's
      loki-read = {
        listen = [{ addr = "0.0.0.0"; port = ports.loki; }];
        locations."/".return = "404";
        locations."/loki/api/v1/" = {
          proxyPass = "http://${loopback}:${toString ports.lokiLocal}";
          extraConfig = ''
            limit_except GET { deny all; }
            proxy_set_header ${telemetry.tenantHeader} $read_tenant;
          '';
        };
      };
      loki-push = pushDoor { port = ports.lokiPush; body = pushBodyBytes.loki; local = ports.lokiLocal; paths = [ "/loki/api/v1/push" ]; };
      otlp-http = pushDoor { port = ports.otlpHttp; body = pushBodyBytes.otlp; local = ports.otlpHttpLocal; paths = [ "/v1/traces" ]; };
      otlp-grpc = pushDoor { port = ports.otlpGrpc; body = pushBodyBytes.otlp; local = ports.otlpGrpcLocal; paths = [ otlpGrpcExport ]; grpc = true; };
      # the legacy ingest api (pyroscope-rs, the template's agent) and the connect push api (alloy)
      pyroscope-push = pushDoor {
        port = ports.pyroscope;
        body = pushBodyBytes.pyroscope;
        local = ports.pyroscopeLocal;
        paths = [ "/ingest" "/push.v1.PusherService/Push" ];
      };
    };
  };

  systemd.services.prometheus-hass-token = {
    description = "Stage the Home Assistant token for the Prometheus scrape";
    before = [ "prometheus.service" ];
    requiredBy = [ "prometheus.service" ];
    after = [ "remote-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
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
        http_addr = "0.0.0.0";
        http_port = ports.grafana;
        root_url = "https://${net.fqdn lab.routes.grafana.host}";
      };
      # gated by authelia forwardauth
      auth.disable_login_form = true;
      "auth.anonymous".enabled = false;
      "auth.proxy" = {
        enabled = true;
        header_name = "Remote-User";
        header_property = "username";
        auto_sign_up = true;
        # a guest granted the port is no login: only the ingress names the user
        whitelist = "${(ingressOf "internal").ip}, ${loopback}";
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
      };
      users = {
        allow_sign_up = false;
        # single-user lab: authelia users are admin
        auto_assign_org_role = "Admin";
      };
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
            jsonData = lokiJsonData // tenantHeader;
            secureJsonData.httpHeaderValue1 = lokiTenants;
          }
        ];
      };
      dashboards.settings.providers = [
        { name = "Default"; options.path = "/etc/grafana-dashboards"; }
        # one folder per app, holding its generated board and, from the share, the boards it ships
        { name = "Apps"; options = { path = "/etc/${appBoardsDir}"; foldersFromFilesStructure = true; }; }
        {
          name = "App boards";
          updateIntervalSeconds = appImportScanS;
          options = { path = "${appImportsMount}/${telemetry.appDashboardsDir}"; foldersFromFilesStructure = true; };
        }
      ];
      alerting = {
        contactPoints.path = config.sops.templates."grafana-contact-points.yaml".path;
        policies.settings = {
          apiVersion = 1;
          # one message per category, re-sent at most daily while it lasts
          policies = [{
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
                object_matchers = [ [ "category" "=" "heartbeat" ] ];
                group_wait = "0s";
                group_interval = "1m";
                repeat_interval = "${toString ntfy.heartbeatIntervalMin}m";
                continue = false;
              }
              { receiver = "telegram"; object_matchers = [ [ "notify" "=" "telegram" ] ]; continue = true; }
              { receiver = "ntfy"; }
            ];
          }];
        };
        rules.settings = {
          apiVersion = 1;
          groups = [{
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = lib.mapAttrsToList ruleOf rules;
          }];
        };
      };
    };
  };

  environment.etc = lib.mapAttrs' (name: board: lib.nameValuePair "grafana-dashboards/${name}.json" { source = board; }) dashboards
    // lib.mapAttrs' (key: board: lib.nameValuePair "${appBoardsDir}/${boardFolderOf key}/service-${key}.json" { source = board; })
      serviceDashboards;

  # the file provider rescans only at startup
  systemd.services.grafana.restartTriggers = lib.attrValues dashboards ++ lib.attrValues serviceDashboards;

  # wholesale price beside the contract price, for the cost panels
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
    timerConfig = { OnCalendar = "*:00/15:05"; Persistent = true; };
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
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=${textfileDir}/${alertsExportFile}.prom
      # no answer means no data, never a stale alert list
      if ! json=$(curl -sf -m10 -H 'Remote-User: admin' \
          'http://${loopback}:${toString ports.grafana}/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'); then
        rm -f "$out"; exit 0
      fi
      {
        echo "# HELP homelab_alert_firing Start time of a firing Grafana alert."
        echo "# TYPE homelab_alert_firing gauge"
        # the watchdog fires by design and is no alert
        echo "$json" | jq -r '
          def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          .[] | select(.labels.category != "heartbeat") | "homelab_alert_firing{alertname=\"\(.labels.alertname // "alert" | esc)\",target=\"\(.labels.vm // .labels.instance // "" | esc)\",severity=\"\(.labels.severity // "" | esc)\",summary=\"\(.annotations.summary // "" | esc)\",fingerprint=\"\(.fingerprint | esc)\"} \(.startsAt | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch now | floor)"'
      } > "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
  systemd.timers.grafana-alerts-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = "30s"; };
  };

  networking.firewall.allowedTCPPorts = with ports; [
    grafana prometheus loki lokiPush otlpGrpc otlpHttp pyroscope journalRemote otlpFrontend
  ];
  # grafana trusts Remote-User (auth.proxy), the query doors read every tenant: the ingress and the grants only. The
  # push doors are open to whoever the router lets through; their tenant map decides what a sender may write
  homelab.ingressOnly.ports = with ports; [ grafana prometheus loki otlpFrontend ];

  # tsdb and loki read their hot blocks from the page cache
  homelab.dropCaches = false;
}
