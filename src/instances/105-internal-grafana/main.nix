{ config, pkgs, lib, inventory, nasMount, nasMountRo, site, catalog, ... }:
let
  telemetry = import ../../modules/telemetry.nix { inherit lib inventory; };
  limits = import ../../modules/limits { inherit lib; };
  ntfy = import ../../modules/ntfy.nix;
  lokiOverrides = pkgs.writeText "loki-overrides.yaml" (builtins.toJSON {
    overrides.${telemetry.labTenant} = {
      ingestion_rate_mb = mibOf limits.lab.logBytesPerSecond;
      ingestion_burst_size_mb = mibOf limits.lab.logBurstBytes;
    };
  });
  # every app tenant, for the admin's view and the lab's alerts over all lines
  lokiTenants = lib.concatStringsSep "|" ([ telemetry.labTenant ] ++ map telemetry.tenantOf (lib.attrNames catalog.apps));
  # loki and pyroscope count their budgets in MiB, fractions allowed
  mibOf = bytes: bytes / (1024.0 * 1024);
  # tempo labels its span metrics with the tenant, so a board and an alert find an app's spans
  tenantLabel = "tenant";
  inherit (telemetry) vmName ports;

  domain = "lsck0.dev";
  # the guests this host talks to by role; every address comes from the inventory
  guest = vmid: inventory.${vmid} or (throw "105-internal-grafana: the inventory has no guest ${vmid}");
  guestAt = ip: lib.findFirst (v: v.ip == ip) (throw "105-internal-grafana: the inventory has no guest at ${ip}") (lib.attrValues inventory);
  collector = guest telemetry.collectorVmid;
  internalIngress = guest "100";
  edgeIngress = guest "200";
  sccache = guest "110";
  terminal = guest "104";
  # the router as this host reaches it: its leg in the internal zone, this host's gateway
  routerAddress = collector.gateway;
  hostSource = v: "${v.ip}/32";
  # what every lab host sends (journals, traces); the swarm workers run strangers' code and are listed per port
  labSources = map hostSource (lib.attrValues (lib.filterAttrs (_: v: v.type != "router" && v.type != "apps") inventory))
    ++ [ "${routerAddress}/32" ];

  # ---- ports, each named once ---------------------------------------------------------------------

  # modules/telemetry.nix names the ports others send to; these are this host's own
  tempoGrpcPort = 9095;
  lokiGrpcPort = 9096;
  blackboxPort = 9115;
  traefikMetricsPort = 8082;
  # 110-internal-cache.nix: sccache's redis
  sccachePort = 6379;
  nodeExporterPort = config.services.prometheus.exporters.node.port;
  # modules/base runs promtail here too, the collector's own journal and the remote ones
  promtailPort = config.services.promtail.configuration.server.http_listen_port;

  # pyroscope: profiles pushed by the app servers (the template's rust agent)
  pyroscopeGrpcPort = 9097;
  # tempo's memberlist default is 7946; nothing joins this ring, it only must not collide
  pyroscopeMemberlistPort = 7947;
  # the single binary dials its own components at the address its rings advertise, eth0 by default, where the
  # ingress guard on 4040 trusts only listed sources (the vm test lists none); loopback also keeps gossip local
  pyroscopeRingAddr = "127.0.0.1";
  pyroscopeRings = [
    "compactor.ring.instance-addr" "distributor.ring.instance-addr" "overrides-exporter.ring.instance-addr"
    "query-frontend.instance-addr" "query-scheduler.ring.instance-addr" "store-gateway.sharding-ring.instance-addr"
    "ingester.lifecycler.addr" "memberlist.advertise-addr" "memberlist.bind-addr"
  ];
  pyroscopeDir = "/var/lib/pyroscope";

  # logs and profiles are kept as long: a profile never outlives the logs around it
  observabilityRetention = "336h";
  # loki's default 5000 cut the template's log panels short
  lokiMaxLines = 10000;
  # the template's datasource timeout: 7d and 30d unique-visitor queries parse every access log line
  lokiQueryTimeoutSeconds = 60;
  # the span metrics' cardinality is bounded here: any lab guest may send spans, and a span name is a label
  tempoMaxActiveSeries = 20000;

  # ---- node-exporter targets ----------------------------------------------------------------------

  nodeJob = "homelab-node-exporter";
  nodeTarget = address: "${address}:${toString nodeExporterPort}";
  router = lib.findFirst (v: v.type == "router") null (lib.attrValues inventory);
  vmLabel = address: name: {
    source_labels = [ "__address__" ];
    regex = lib.replaceStrings [ "." ] [ "\\." ] (nodeTarget address);
    target_label = "vm";
    replacement = name;
  };
  guestsScraped = lib.filterAttrs (_: v: v.type != "router") inventory;
  vmRelabels =
    [{ source_labels = [ "__address__" ]; regex = "([^:]+):.*"; target_label = "vm"; replacement = "$1"; }]
    ++ lib.mapAttrsToList (_: v: vmLabel v.ip (vmName v)) guestsScraped
    ++ lib.optional (router != null) (vmLabel routerAddress (vmName router))
    ++ [ (vmLabel site.lan.proxmox "proxmox") ];

  # guests not meant to run (onDemand, disabled); "up within 30d" instead cost 1.4M samples and hid new guests
  notRunningTargets = lib.mapAttrsToList (_: v: nodeTarget v.ip) (lib.filterAttrs (_: v: v.enabled != "true") inventory);
  guestsExpectedUp = "up{job=\"${nodeJob}\""
    + lib.optionalString (notRunningTargets != [ ])
      ",instance!~\"${lib.concatMapStringsSep "|" (lib.replaceStrings [ "." ] [ "\\\\." ]) notRunningTargets}\""
    + "}";

  # persistent timers catch up within this of a wake; scrape history, since an lxc reports the host's boot time
  upForCatchUp = "min_over_time(up{job=\"${nodeJob}\"}[1h]) == 1";

  # ---- blackbox probes ----------------------------------------------------------------------------

  # the nixos services' own ports (catalog routes bound to a vm); the public names always 302 via authelia
  probes =
    let
      vmRoutes = lib.filterAttrs (_: r: r.vmid != null) (catalog.internal // catalog.external);
      # on-demand/disabled vms would alarm forever; a route may opt out (off.probe)
      alwaysOn = r: inventory.${toString r.vmid}.enabled == "true" && r.off.probe == null;
    in
    lib.mapAttrsToList (name: r: let v = guest (toString r.vmid); in {
      inherit name;
      vm = vmName v;
      url = "http://${v.ip}:${toString r.port}${lib.optionalString (r.health != null) r.health}";
    }) (lib.filterAttrs (_: alwaysOn) vmRoutes)
    # the ingresses own no route
    ++ [
      { name = "traefik-internal"; vm = vmName internalIngress; url = "http://${internalIngress.ip}:80"; }
      { name = "traefik-external"; vm = vmName edgeIngress; url = "http://${edgeIngress.ip}:80"; }
    ];
  # at the backend the router forwards to; udp has no generic probe, and a guest that sleeps would alarm forever
  l4Probes = lib.mapAttrsToList (name: r: let
    node = if r.vmid != null then guest (toString r.vmid) else guestAt (lib.head r.nodes);
  in { inherit name; vm = vmName node; target = "${node.ip}:${toString r.port}"; })
    (lib.filterAttrs (_: r: r.protocol == "tcp" && r.off.probe == null
      && (r.vmid == null || inventory.${toString r.vmid}.enabled == "true")) catalog.l4);
  probeRelabels = [
    { source_labels = [ "__address__" ]; target_label = "__param_target"; }
    { source_labels = [ "__param_target" ]; target_label = "instance"; }
    { target_label = "__address__"; replacement = "127.0.0.1:${toString blackboxPort}"; }
  ];

  # ---- swarm apps ---------------------------------------------------------------------------------

  # app stacks (src/apps/): scraped, traced, profiled and alerted on here; a disabled app leaves none of it
  appsConfig = config.homelab.appsCatalog;
  # the same view of the apps the ingresses and the router route by
  appsEnabled = catalog.apps;
  appsTelemetry = lib.filterAttrs (_: telemetry.sendsSignals) appsEnabled;
  appsWithMetric = name: lib.filterAttrs (app: _: alerted ? ${app} && exportersOf alerted.${app} ? ${name}) appsEnabled;
  # every node app tasks run on: the shared swarm's workers and each guest-placed app's own guest (its swarm of one)
  appNodes = map guest (lib.sort (a: b: lib.toInt a < lib.toInt b)
    (lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters))));
  appNodeSources = map hostSource appNodes;
  # the template's dashboards rate over [1m], four samples at 15s; the lab default of 1m leaves one
  appScrapeInterval = "15s";
  appScrapeConfigs = lib.optional (appsEnabled != { }) {
    # per node: each cadvisor sees only its own node's containers
    job_name = "app-cadvisor";
    scrape_interval = appScrapeInterval;
    static_configs = map (node: {
      targets = [ "${node.ip}:${toString appsConfig.cadvisorPort}" ];
      labels.vm = vmName node;
    }) appNodes;
    metric_relabel_configs = [
      # every systemd slice is a cgroup too; only containers carry a name, the rest is cardinality
      { source_labels = [ "__name__" "name" ]; regex = "container_.*;"; action = "drop"; }
      { source_labels = [ "name" ]; regex = telemetry.swarmTaskPatterns.service; target_label = "swarm_service"; }
      { source_labels = [ "name" ]; regex = telemetry.swarmTaskPatterns.stack; target_label = "swarm_stack"; }
    ];
  }
  ++ lib.optional (appsEnabled != { }) {
    # each worker's log shipper: what it dropped per app above the app's budget (modules/app-telemetry.nix)
    job_name = config.homelab.appTelemetry.shipperJob;
    scrape_interval = appScrapeInterval;
    static_configs = map (node: {
      targets = [ "${node.ip}:${toString ports.promtail}" ];
      labels.vm = vmName node;
    }) appNodes;
  };

  edgeTraefikTarget = "${edgeIngress.ip}:${toString traefikMetricsPort}";

  # ---- every service: a nixos guest's (instance.nix `services`) and a swarm app, one record each ------

  # a guest that is off on purpose has nothing to scrape, draw or alert on
  services = lib.filterAttrs (_: s: s.kind == "swarm" || inventory.${toString s.vmid}.enabled != "false") catalog.services;
  servicesOn = feature: lib.filterAttrs (_: s: s.on.${feature}) services;
  alerted = servicesOn "alerts";
  isApp = s: s.kind == "swarm";
  exportersOf = s: if s.on.metrics then s.metrics else { };
  # an app's exporter answers on any node of its cluster's routing mesh (one, or each sample counts once per node)
  exporterNodeOf = s: if isApp s then guestAt (lib.head s.cluster.nodes) else guest (toString s.vmid);
  exporterJobOf = key: s: name: "${if isApp s then "app" else "service"}-${key}-${name}";
  exporterJobsOf = set: lib.concatLists (lib.mapAttrsToList (key: s: map (exporterJobOf key s) (lib.attrNames (exportersOf s))) set);
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
  # both ingresses name a route's traefik service after the route: exact names, a prefix would also match <name>-x
  traefikSelector = set: "service=~\"(${lib.concatMapStringsSep "|" (n: "${n}@file") (lib.concatMap (s: s.routes) (lib.attrValues set))})\"";
  regexOf = names: "(${lib.concatStringsSep "|" names})";
  alertedApps = lib.attrNames (lib.filterAttrs (_: isApp) alerted);
  alertedAwake = lib.filterAttrs (_: s: isApp s && s.idle.stopAfter == null) alerted;
  # a client bug's steady trickle stays under 5%, a broken backend does not
  app5xxPercent = 5;
  # a page that takes longer than this is broken for its user, whatever it answers
  appLatencySeconds = 2;
  # a task this close to its memory limit for a quarter hour is about to be killed by it
  appSaturationPercent = 90;
  # below this the share is noise: one failed request out of three is not an outage
  app5xxMinRequestsPerSecond = "0.1";
  # the traefik job scrapes every 1m: four samples
  traefikRateWindow = "5m";
  # start-first replaces a task once per deploy: a deploy is two tasks in the window, two quick ones three
  restartLoopWindow = "15m";
  restartLoopTasks = 3;
  # the template's wal-g loop (services/storage/postgres/wal-g-backup-loop.sh) logs this once a day and
  # exports no metric; its postgres service is named postgres in the stack
  walgSuccessLine = "Backup completed successfully";
  walgService = "postgres";
  # the loop sleeps a day between pushes; the extra 2h covers the push itself
  walgStaleSeconds = 26 * 3600;
  # vm-119 is awake a few hours a night: its last value of the day, with slack for a late build
  archrepoLookback = "26h";

  # ---- storage --------------------------------------------------------------------------------------

  # disks: ext4 data filesystems; /nix/store is a bind of / and would double every alert
  diskSelector = "fstype=\"ext4\",mountpoint!=\"/nix/store\"";
  diskUsedPercent = selector:
    "100 * (1 - node_filesystem_avail_bytes{${selector}} / node_filesystem_size_bytes{${selector}})";
  # a 3d trend smooths nightly dumps and gc; two weeks is time to order a disk or clean up
  diskForecastWindow = "3d";
  diskForecastHorizonSeconds = 14 * 86400;
  thinpoolDataWarnPercent = 80;
  thinpoolDataCriticalPercent = 90;
  # metadata exhaustion corrupts every thin volume at once, so it warns earlier than data
  thinpoolMetadataPercent = 70;
  # a drive's rated endurance; past it, writes may fail without warning
  nvmeWearRatio = 0.8;

  prometheusRetentionTime = "10y";
  # energy history is the long-lived data, ~1GB a month; the nas data pool is shared with every guest's
  # state, so this cap, not the 10y, ends the history once it is reached
  prometheusRetentionSize = "50GB";

  # ---- monitoring of the monitoring -----------------------------------------------------------------

  # the units an alert depends on; node-exporter's systemd collector reports exactly these
  monitoringUnits = [
    "grafana" "prometheus" "nginx" "loki" "tempo" "pyroscope" "promtail" "systemd-journal-remote"
    "prometheus-blackbox-exporter"
  ];
  # [.]: a literal dot that needs no backslash, which systemd's ExecStart and a promql string would each unescape
  monitoringUnitsRegex = "(${lib.concatStringsSep "|" monitoringUnits})[.]service";
  # thirty guests log several lines a second; under one line in 100 s for a quarter hour, the pipeline stopped
  logLinesMinPerSecond = 0.01;
  # the external check (vm-203) alerts after three missed heartbeats
  heartbeatInterval = "${toString ntfy.heartbeatIntervalMin}m";

  # ---- alert delivery ---------------------------------------------------------------------------------

  # alerts also go to hermes telegram
  enableTelegram = true;

  # ntfy (vm-203) requires a login
  ntfyBase = "https://ntfy.${domain}";
  ntfyAlertTopic = ntfy.topics.alerts;
  # vm-203 watches this topic and alerts on ntfyAlertTopic when it falls silent
  ntfyHeartbeatTopic = ntfy.topics.heartbeat;

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

  # a notification groups the alerts of one category: one header, one line per alert
  categories = {
    offline = { firing = "Offline"; resolved = "Back online"; };
    service = { firing = "Service down"; resolved = "Service back"; };
    backups = { firing = "Backups missing"; resolved = "Backups running again"; };
    attack = { firing = "Attack detected"; resolved = "Attack over"; };
    storage = { firing = "Storage needs attention"; resolved = "Storage ok"; };
    apps = { firing = "Apps failing"; resolved = "Apps ok"; };
    builds = { firing = "Builds failing"; resolved = "Builds ok"; };
    monitoring = { firing = "Monitoring degraded"; resolved = "Monitoring ok"; };
    heartbeat = { firing = "Alerting alive"; resolved = "Alerting stopped"; };
  };

  /*
    mkRule: one Grafana-managed rule, query A thresholded by C. Fields, with their defaults:

      uid          string, required     stable id; a removed rule stays in grafana's db until listed in deleteRules
      title        string, required     the rule's name in grafana
      category     attr of categories   groups notifications and names their header (firing / resolved text)
      expr         string, required     PromQL, or LogQL with datasource = "loki"
      op           "gt"                 threshold comparison: gt, lt
      threshold    number, required
      for          "5m"                 how long the condition holds before it fires
      noData       "OK"                 Alerting where silence itself is the failure (a backup timestamp, a log line)
      severity     "warning"            "critical" for what needs action today
      telegram     false                true pages over telegram besides ntfy; paging is opt-in
      datasource   "prometheus"         or "loki"
      range        600                  seconds the query looks back (loki rules)
      summary      string, required     one line per alert; go template over $labels and $values
      description  string, required     what it means and the first command to run

    execErrState is KeepLast: prometheus or loki restarting is not every rule firing at once. A rule that can no
    longer evaluate (a renamed metric, a typo) stays inactive with health "error"; tests/monitoring.nix asserts
    every provisioned rule's health is ok.
  */
  mkRule = r: {
    inherit (r) uid title;
    condition = "C";
    data = [
      {
        refId = "A";
        relativeTimeRange = { from = r.range or 600; to = 0; };
        datasourceUid = r.datasource or "prometheus";
        model = { refId = "A"; expr = r.expr; instant = true; }
          // lib.optionalAttrs ((r.datasource or "") == "loki") { queryType = "instant"; };
      }
      {
        refId = "C";
        datasourceUid = "__expr__";
        model = {
          refId = "C";
          type = "threshold";
          expression = "A";
          conditions = [{ evaluator = { type = r.op or "gt"; params = [ r.threshold ]; }; }];
        };
      }
    ];
    for = r.for or "5m";
    noDataState = r.noData or "OK";
    execErrState = r.execErr or "KeepLast";
    labels = { severity = r.severity or "warning"; category = r.category; }
      // lib.optionalAttrs (r.telegram or false) { notify = "telegram"; };
    annotations = { inherit (r) summary description; } // categories.${r.category};
  };

  # single delivery path: Grafana unified alerting
  contactPoints = {
    apiVersion = 1;
    contactPoints = [{
      orgId = 1;
      name = "ntfy";
      receivers = [{
        uid = "ntfy_cp";
        type = "webhook";
        settings = {
          url = "${ntfyBase}/${ntfyAlertTopic}?${ntfyQuery}";
          httpMethod = "POST";
          # ntfy denies anonymous publishing
          username = "grafana";
          password = config.sops.placeholder.ntfy-grafana-password;
        };
        disableResolveMessage = false;
      }];
    } {
      orgId = 1;
      name = "heartbeat";
      receivers = [{
        uid = "heartbeat_cp";
        type = "webhook";
        settings = {
          url = "${ntfyBase}/${ntfyHeartbeatTopic}?${ntfyHeartbeatQuery}";
          httpMethod = "POST";
          username = "grafana";
          password = config.sops.placeholder.ntfy-grafana-password;
        };
        # silence is the signal; a resolve message would be one more heartbeat
        disableResolveMessage = true;
      }];
    }] ++ lib.optional enableTelegram {
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
    };
  };

  # ---- rules ----------------------------------------------------------------------------------------

  rules = [
    # dead man's switch: always firing, vm-203 alerts when it stops arriving on the heartbeat topic
    {
      uid = "watchdog";
      title = "Watchdog";
      category = "heartbeat";
      expr = "up{job=\"prometheus\"}";
      threshold = 0;
      for = "0m";
      # prometheus not answering resolves it, which stops the heartbeat
      execErr = "OK";
      summary = "vm-105 evaluates rules and delivers notifications";
      description = "Always firing on purpose. Its absence on ntfy topic ${ntfyHeartbeatTopic} is the alert.";
    }
    {
      uid = "instance_down";
      title = "Guest offline";
      category = "offline";
      expr = guestsExpectedUp;
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} is offline";
      description = "node-exporter has been unreachable for 5 minutes. Check `vm status <id>` and the guest's journal.";
    }
    {
      uid = "service_down";
      title = "Service not answering";
      category = "service";
      # a guest that is down is the offline alert's, not one more per route on it
      expr = "probe_success and on (vm) (up{job=\"${nodeJob}\"} == 1)";
      op = "lt"; threshold = 1;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.service }} on {{ $labels.vm }} does not answer";
      description = "The blackbox probe of the service's own port has failed for 10 minutes while its guest is up.";
    }
    # no backups taken
    {
      uid = "backup_stale";
      title = "NAS snapshot stale";
      category = "backups";
      expr = "time() - max(homelab_backup_last_success_timestamp_seconds{type=\"daily\"})";
      threshold = 26 * 3600;
      # missing data alerts too, but only once prometheus had time to scrape after a boot
      for = "30m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "NAS snapshot: none in over 26h";
      description = "Kopia on vm-109 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server`.";
    }
    {
      uid = "offsite_stale";
      title = "Off-site copy stale";
      category = "backups";
      expr = "time() - max(homelab_offsite_last_success_timestamp_seconds)";
      # a failed night is tolerated (proton's api fails runs now and then), plus start jitter and run length
      threshold = 60 * 3600;
      for = "30m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "Off-site (Proton Drive): no upload in over 60h";
      description = "proton-sync on vm-109 has not finished. Check `journalctl -u proton-sync`.";
    }
    {
      uid = "db_dump_stale";
      title = "Database dump stale";
      category = "backups";
      expr = "(time() - max by (vm, db) (homelab_db_dump_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = 26 * 3600;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.db }} dump on {{ $labels.vm }}: none in over 26h";
      description = "The nightly db-backup-<name> unit on that guest failed; the snapshot then holds only a live copy.";
    }
    {
      uid = "state_mirror_stale";
      title = "Local state mirror stale";
      category = "backups";
      expr = "(time() - max by (vm, state) (homelab_local_state_mirror_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = 26 * 3600;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.state }} mirror on {{ $labels.vm }}: none in over 26h";
      description = "The nightly <name>-mirror unit on that guest failed; the NAS copy, and with it the snapshot, is behind the guest's disk.";
    }
    # vm-119's nightly arch repo build (its textfile gauges exist only while it is awake)
    {
      uid = "archrepo_missing";
      title = "Arch mirror lacks listed packages";
      category = "builds";
      expr = "last_over_time(homelab_archrepo_missing_packages[${archrepoLookback}])";
      threshold = 0;
      for = "0m";
      summary = "lsck0 snapshot: {{ $values.A }} listed packages missing";
      description = "Listed in arch-dotfiles but not served by mirror.lsck0.dev; a fresh install misses them. `curl -s http://${(guest "119").ip}/status.txt` lists them, logs/<base>.log says why.";
    }
    {
      uid = "archrepo_held_back";
      title = "Arch mirror snapshot held back";
      category = "builds";
      expr = "last_over_time(homelab_archrepo_held_back[${archrepoLookback}])";
      threshold = 0;
      for = "0m";
      summary = "lsck0 snapshot held back";
      description = "The nightly build did not publish; status.txt `published:` says why. Clients keep the previous snapshot.";
    }
    # attacks
    {
      uid = "attack_flood";
      title = "Traffic flood";
      category = "attack";
      # crowdsec blocks tens of scans an hour; only a sustained flood orders of magnitude above that wakes anyone
      expr = "sum(rate(traefik_entrypoint_requests_total{entrypoint=\"websecure\"}[5m]))";
      threshold = 50;
      for = "15m";
      telegram = true;
      summary = "{{ $values.A.Value | printf \"%.0f\" }} req/s sustained 15m: possible DoS";
      description = "Requests are far above baseline for 15 minutes. CrowdSec blocks known-bad; check `cscli metrics` and top talkers on vm-200. Routine scans do not trigger this.";
    }
    {
      uid = "sso_bruteforce";
      title = "Failed SSO logins";
      category = "attack";
      datasource = "loki";
      range = 900;
      # one failed login a week is normal; authelia's own host, not whatever host a journal claims
      expr = "sum(count_over_time({host=\"vm-101\", unit=\"authelia-main.service\"} |= \"Unsuccessful 1FA\" [15m]))";
      threshold = 4;
      for = "0m";
      telegram = true;
      summary = "{{ $values.A.Value }} failed SSO logins in 15 minutes";
      description = "Authelia rejected these passwords; it bans a user after 3 tries in 2 minutes.";
    }
    # storage
    {
      uid = "media_quota";
      title = "Media quota almost full";
      category = "storage";
      expr = "100 * max(homelab_media_bytes) / max(homelab_media_quota_bytes)";
      threshold = 95;
      for = "1h";
      summary = "media and torrents at {{ printf \"%.0f\" $values.A.Value }}% of their quota";
      description = "Downloads and imports stop at the quota (109-internal-nas.nix mediaQuotaGiB). Let janitorr clean up, delete media, or raise the quota.";
    }
    {
      uid = "disk_full";
      title = "Disk almost full";
      category = "storage";
      expr = diskUsedPercent diskSelector;
      threshold = 90;
      for = "30m";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used";
      description = "A guest filesystem is over 90%. Old generations, journal or images usually; on the nas bulk disk or the download disk, media.";
    }
    {
      uid = "disk_critical";
      title = "Disk full";
      category = "storage";
      expr = diskUsedPercent diskSelector;
      threshold = 95;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used, writes fail soon";
      description = "Writes on this filesystem fail soon: databases stop, journals and downloads break. Free space now.";
    }
    {
      uid = "disk_fill_predicted";
      title = "Disk fills within two weeks";
      category = "storage";
      expr = "predict_linear(node_filesystem_avail_bytes{${diskSelector}}[${diskForecastWindow}], ${toString diskForecastHorizonSeconds})";
      op = "lt"; threshold = 0;
      # a trend, not a spike: nightly dumps and downloads come and go within hours
      for = "2h";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: full within 14 days at the 3-day trend";
      description = "The free space trend of the last 3 days reaches zero within two weeks. Find what grows before it is full.";
    }
    # the proxmox host's textfile collector, one series per pool; no data until it exists
    {
      uid = "thinpool_data_warn";
      title = "Thin pool filling";
      category = "storage";
      expr = "homelab_thinpool_data_percent";
      threshold = thinpoolDataWarnPercent;
      for = "30m";
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} data at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Trim guests or grow the pool.";
    }
    {
      uid = "thinpool_data_critical";
      title = "Thin pool almost full";
      category = "storage";
      expr = "homelab_thinpool_data_percent";
      threshold = thinpoolDataCriticalPercent;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} data at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Free space now: fstrim the guests, drop snapshots.";
    }
    {
      uid = "thinpool_metadata";
      title = "Thin pool metadata filling";
      category = "storage";
      expr = "homelab_thinpool_metadata_percent";
      threshold = thinpoolMetadataPercent;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} metadata at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Full thin pool metadata corrupts the pool. Grow it with lvextend --poolmetadatasize.";
    }
    # the proxmox host's smartmon and nvme collectors (prometheus-node-exporter-collectors); no data until installed
    {
      uid = "disk_health";
      title = "Disk failing";
      category = "storage";
      expr = "smartmon_device_smart_healthy";
      op = "lt"; threshold = 1;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.disk }} on {{ $labels.vm }}: SMART health check failed";
      description = "The drive reports itself as failing. Check that the backups are current, then replace it.";
    }
    {
      uid = "nvme_wear";
      title = "NVMe worn";
      category = "storage";
      expr = "nvme_percentage_used_ratio";
      threshold = nvmeWearRatio;
      for = "1h";
      summary = "{{ $labels.device }} on {{ $labels.vm }}: {{ humanizePercentage $values.A.Value }} of its rated writes used";
      description = "Past its rated endurance an ssd may fail without warning. Plan its replacement.";
    }
    # monitoring itself
    {
      uid = "monitoring_unit_down";
      title = "Monitoring unit down";
      category = "monitoring";
      expr = "node_systemd_unit_state{state=\"active\",name=~\"${monitoringUnitsRegex}\"}";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.name }} on vm-105 is not active";
      description = "A part of the metrics, logs or alerting pipeline stopped; alerts that need it cannot fire. `systemctl status {{ $labels.name }}` on vm-105.";
    }
    {
      uid = "logs_not_arriving";
      title = "No logs arriving";
      category = "monitoring";
      expr = "sum(rate(loki_distributor_lines_received_total[15m]))";
      op = "lt"; threshold = logLinesMinPerSecond;
      for = "15m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "Loki has received no log lines for 15 minutes";
      description = "journal-remote, promtail or loki on vm-105 stopped forwarding; the log alerts (failed logins, wal-g) see nothing. `journalctl -u promtail -u systemd-journal-remote` on vm-105.";
    }
    {
      uid = "promtail_dropping";
      title = "Log lines dropped";
      category = "monitoring";
      expr = "sum by (vm, reason) (increase(promtail_dropped_entries_total[1h]))";
      threshold = 0;
      for = "0m";
      summary = "promtail on {{ $labels.vm }} dropped {{ printf \"%.0f\" $values.A.Value }} lines in the last hour ({{ $labels.reason }})";
      description = "Loki refused or promtail gave up on log lines, so they are gone. `journalctl -u promtail` on that guest.";
    }
  ] ++ lib.optional (exporterJobsOf alerted != [ ]) {
    uid = "app_target_down";
    title = "Service metrics unreachable";
    category = "service";
    # an app asleep (idle) or a guest that is down has no exporter to reach; the guest is the offline alert's
    expr = "up{job=~\"${regexOf (exporterJobsOf alerted)}\"} unless on (app) homelab_app_idle_stopped == 1 and on (vm) (up{job=\"${nodeJob}\"} == 1)";
    op = "lt"; threshold = 1;
    severity = "critical"; telegram = true;
    summary = "{{ $labels.job }} on {{ $labels.vm }} does not answer";
    description = "Prometheus has not reached this exporter for 5 minutes: the service is down, crash looping or not published.";
  } ++ lib.optionals (alerted != { }) [
    {
      uid = "app_5xx";
      title = "Service answering 5xx";
      category = "service";
      expr = let
        requests = filter: "sum by (service) (rate(traefik_service_requests_total{${traefikSelector alerted}${filter}}[${traefikRateWindow}]))";
      in "100 * (${requests ",code=~\"5..\""} / ${requests ""}) and on (service) (${requests ""} > ${app5xxMinRequestsPerSecond})";
      threshold = app5xxPercent;
      for = "10m";
      telegram = true;
      summary = "{{ $labels.service }}: {{ printf \"%.0f\" $values.A.Value }}% of requests fail with 5xx";
      description = "Over ${toString app5xxPercent}% of the requests traefik sends this route fail with 5xx. Its board (Services) holds its logs.";
    }
    {
      uid = "app_slow";
      title = "Service answering slowly";
      category = "service";
      expr = let
        requests = "sum by (service) (rate(traefik_service_requests_total{${traefikSelector alerted}}[${traefikRateWindow}]))";
        buckets = "traefik_service_request_duration_seconds_bucket{${traefikSelector alerted}}";
      in "histogram_quantile(0.95, sum by (service, le) (rate(${buckets}[${traefikRateWindow}])))"
        + " and on (service) (${requests} > ${app5xxMinRequestsPerSecond})";
      threshold = appLatencySeconds;
      for = "15m";
      summary = "{{ $labels.service }}: 95% of requests take up to {{ printf \"%.1f\" $values.A.Value }}s";
      description = "The route's p95 latency at its ingress is above ${toString appLatencySeconds}s. Its board shows whether it is cpu-throttled, out of memory or waiting on a store.";
    }
  ] ++ lib.optionals (alertedApps != [ ]) [
    {
      uid = "app_restart_loop";
      title = "App container restart loop";
      category = "apps";
      # each restart is a new task container, so the distinct names seen in the window
      expr = "count by (swarm_service) (count_over_time(container_start_time_seconds{swarm_stack=~\"${regexOf alertedApps}\"}[${restartLoopWindow}]))";
      threshold = restartLoopTasks;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.swarm_service }}: {{ $values.A.Value }} tasks in ${restartLoopWindow}, restart loop";
      description = "Swarm keeps replacing this service's task. `docker service ps --no-trunc <service>` on an apps node shows why.";
    }
    {
      uid = "app_deploy_failed";
      title = "App deploy failed";
      category = "apps";
      # the builder (instances/140-internal-swarm/lib/app-builder.nix) writes it after every build and deploy
      expr = "min by (app) (homelab_app_deploy_ok{app=~\"${regexOf alertedApps}\"})";
      op = "lt"; threshold = 1;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.app }}: the last build or deploy failed, the previous version keeps running";
      description = "The builder could not build or deploy the app's newest commit; it retries with backoff (5 min, doubling to 6 h) and on every new commit, `app-builder-redeploy <app>` forces it. `journalctl -u app-builder -u 'app-builder@*'` on vm-${toString appsConfig.builder}.";
    }
    {
      uid = "app_swarm_deploy_failed";
      title = "App deploy failed on the manager";
      category = "apps";
      expr = "min by (app) (homelab_swarm_deploy_ok{app=~\"${regexOf alertedApps}\"})";
      op = "lt"; threshold = 1;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.app }}: the manager could not roll out the app, the previous version keeps running";
      description = "swarm-deploy on vm-140 refused, could not roll out, or the swarm rolled back the app. `journalctl -t swarm-deploy -u swarm-converge` on vm-140.";
    }
    {
      uid = "app_unreachable";
      title = "App has no healthy backend";
      category = "apps";
      # an idle app's routes go through the wake proxy, which holds its first request until it answers
      expr = "max by (service) (traefik_service_server_up{instance=\"${edgeTraefikTarget}\",${traefikSelector alertedAwake}})";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.service }}: no worker answers its health check";
      description = "The edge's health check fails on every worker for this route: the app is down for its users. Its tasks: `docker service ps <app>_<service>` on vm-140.";
    }
    {
      uid = "app_memory_saturated";
      title = "App task near its memory limit";
      category = "apps";
      expr = let tasks = "swarm_stack=~\"${regexOf alertedApps}\""; in
        "100 * max by (swarm_service) (container_memory_working_set_bytes{${tasks}} / (container_spec_memory_limit_bytes{${tasks}} > 0))";
      threshold = appSaturationPercent;
      for = "15m";
      summary = "{{ $labels.swarm_service }}: {{ printf \"%.0f\" $values.A.Value }}% of its memory limit";
      description = "The task reclaims and will be killed inside its own limit. Raise apps.<app>.resources.<service>.memoryMiB (and its reservation) or fix the leak.";
    }
  ] ++ lib.optional (appsWithMetric "postgres" != { }) {
    uid = "app_postgres_down";
    title = "App database down";
    category = "apps";
    expr = "min by (app) (pg_up)";
    op = "lt"; threshold = 1;
    severity = "critical"; telegram = true;
    summary = "{{ $labels.app }}: postgres down";
    description = "postgres_exporter answers but cannot reach postgres. Check the stack's postgres service on the apps nodes.";
  } ++ lib.optional (appsWithMetric "redis" != { }) {
    uid = "app_redis_down";
    title = "App cache down";
    category = "apps";
    expr = "min by (app) (redis_up)";
    op = "lt"; threshold = 1;
    severity = "critical"; telegram = true;
    summary = "{{ $labels.app }}: redis down";
    description = "redis_exporter answers but cannot reach redis. Check the stack's redis service on the apps nodes.";
  } ++ lib.mapAttrsToList (app: _: {
    uid = "app_${app}_walg_stale";
    title = "${app} WAL-G backup stale";
    category = "backups";
    datasource = "loki";
    range = walgStaleSeconds;
    expr = "sum(count_over_time({swarm_service=\"${app}_${walgService}\"} |= \"${walgSuccessLine}\" [${toString walgStaleSeconds}s]))";
    op = "lt"; threshold = 1;
    for = "30m";
    # no success line in the window is no series at all
    noData = "Alerting";
    severity = "critical"; telegram = true;
    summary = "${app} postgres: no WAL-G base backup in over ${toString (walgStaleSeconds / 3600)}h";
    description = "The stack's wal-g loop has not logged a successful backup-push. Its log: {swarm_service=\"${app}_${walgService}\"} in Loki.";
  }) (appsWithMetric "postgres");

  # retired rule uids: a rule dropped from `rules` stays in grafana's db until it is listed here
  retiredRules = [
    "ossec_alert" "crowdsec_burst"
    # superseded by thinpool_data_* once the pool itself was measured
    "nas_root_thinpool"
  ];

  # ---- programs and boards ----------------------------------------------------------------------------

  energyModel = import ../../modules/energy { inherit pkgs; };
  feedIo = import ../../modules/feeds { inherit pkgs; };
  python = name: libraries: file: pkgs.writers.writePython3Bin name {
    inherit libraries;
    flakeIgnore = [ "E501" ];
  } (builtins.readFile file);

  # inverter solar api, polled per scrape
  froniusExporter = python "fronius-exporter" [ ] ./lib/fronius-exporter.py;
  froniusListen = "127.0.0.1:9118";
  # a site without a fronius inverter (site.json) has no house power data
  inverter = site.lan.inverter != "";
  # local copy: a missing nas token must fail one scrape, not prometheus
  hassScrapeToken = "/run/prometheus-hass/token";
  homeAssistant = catalog.internal.homeassistant;

  spotPrice = python "spot-price" [ energyModel feedIo ] ./lib/spot-price.py;
  spotPriceState = "/var/lib/spot-price";
  inherit (config.homelab) textfileDir;

  # generated, so a board cannot drift from the queries it shares (energy_model, the alert expressions)
  dashboardPython = pkgs.python3.withPackages (_: [ energyModel ]);
  dashboard = name: script: config: pkgs.runCommand "${name}.json" {
    config = builtins.toJSON config;
    passAsFile = [ "config" ];
  } ''
    PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${script} "$configPath" $out
  '';
  homelabDashboard = dashboard "homelab" ./lib/dashboards/homelab.py {
    uid = telemetry.homelabDashboardUid;
    inherit nodeJob guestsExpectedUp edgeHost;
    ssoHost = "vm-101";
    nasVm = vmName (guest "109");
    hostVm = "proxmox";
  };
  # energy.py takes no config, every query is energy_model's
  energyDashboard = pkgs.runCommand "energy.json" { } ''
    PYTHONPATH=${./lib/dashboards} ${dashboardPython}/bin/python3 ${./lib/dashboards/energy.py} $out
  '';
  # the public ingress; its promtail labels the access log with this host
  edgeHost = "vm-200";
  # an ingress's routes as the board reads them: by traefik name, access log host and metrics instance
  boardRoutes = ingress: routes: lib.mapAttrsToList (name: r: {
    inherit name;
    host = "${r.host}.${domain}";
    ingress = "vm-${toString ingress.vmid}";
    instance = "${ingress.ip}:${toString traefikMetricsPort}";
  }) routes;
  lokiJsonData = { maxLines = lokiMaxLines; timeout = lokiQueryTimeoutSeconds; };
  # each app reads its own tenant: its logs, and with telemetry its traces (linked into its logs) and profiles
  tenantDatasources = lib.concatLists (lib.mapAttrsToList (app: a: let
    header = { httpHeaderName1 = telemetry.tenantHeader; };
    tenant = { httpHeaderValue1 = telemetry.tenantOf app; };
  in [
    {
      name = "Loki ${app}";
      type = "loki";
      access = "proxy";
      url = "http://127.0.0.1:${toString ports.lokiLocal}";
      uid = "loki-${app}";
      secureJsonData = tenant;
      jsonData = lokiJsonData // header;
    }
  ] ++ lib.optional (a.off.traces == null) {
      name = "Tempo ${app}";
      type = "tempo";
      access = "proxy";
      url = "http://127.0.0.1:${toString ports.tempo}";
      uid = "tempo-${app}";
      secureJsonData = tenant;
      jsonData = header // {
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
    }
  ++ lib.optional (a.off.profiles == null) {
      name = "Pyroscope ${app}";
      type = "grafana-pyroscope-datasource";
      access = "proxy";
      url = "http://127.0.0.1:${toString ports.pyroscope}";
      uid = "pyroscope-${app}";
      secureJsonData = tenant;
      jsonData = header;
    }
  ) appsEnabled);
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
      "otlphttp/tempo" = { endpoint = "http://127.0.0.1:${toString ports.otlpHttp}"; auth.authenticator = "headers_setter"; };
      "otlphttp/loki" = { endpoint = "http://127.0.0.1:${toString ports.lokiLocal}/otlp"; auth.authenticator = "headers_setter"; };
      "otlphttp/prometheus".endpoint = "http://127.0.0.1:${toString ports.prometheusLocal}/api/v1/otlp";
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
    vm = vmName (guest (toString s.vmid));
    routesIn = routes: lib.filterAttrs (name: _: lib.elem name s.routes) routes;
  in {
    name = key;
    routes = boardRoutes (internalIngress // { vmid = 100; }) (routesIn catalog.internal)
      ++ boardRoutes (edgeIngress // { vmid = 200; }) (routesIn catalog.external);
    forwards = if routesIn catalog.l4 == { } || router == null then null else {
      host = router.name;
      loki = "loki";
      routes = lib.mapAttrsToList (name: r: { inherit name; inherit (r) protocol; port = r.publicPort; }) (routesIn catalog.l4);
    };
    deploys = app;
    idle = app && s.idle.stopAfter != null;
    containers = if app then "swarm_stack=\"${key}\"" else null;
    vm = if app then null else vm;
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
    cadvisorJob = "app-cadvisor";
    shipperJob = config.homelab.appTelemetry.shipperJob;
    inherit nodeJob;
    rateWindow = traefikRateWindow;
  }) (servicesOn "dashboard");
  serviceDashboards = lib.mapAttrs (name: board: dashboard name ./lib/dashboards/service.py board) serviceBoards;
  overviewDashboard = dashboard "services" ./lib/dashboards/service.py { services = lib.attrValues serviceBoards; };
  # each app's folder: its generated board here, the boards it ships on the share the deploy controller writes
  appBoardsDir = "grafana-apps";
  # the lab's own services share one folder; its name is no valid app name, so no app's folder can take it
  boardFolderOf = key: if isApp services.${key} then key else "Lab services";
  appImportsMount = "/var/lib/app-dashboards";
  appImportScanS = 60;
  dashboards = { homelab = homelabDashboard; energy = energyDashboard; services = overviewDashboard; };
in {
  networking.hostName = "vm-105";

  # the home assistant scrape
  homelab.tokens.reads = [ "hass-key" ];

  # bot token, chat id, ntfy password from sops
  sops.secrets = {
    ntfy-grafana-password = {};
  } // lib.optionalAttrs enableTelegram {
    telegram-bot-token = {};
    telegram-chat-id = {};
  };
  sops.templates."grafana-contact-points.yaml" = {
    owner = "grafana";
    content = builtins.toJSON contactPoints;
  };

  homelab.nasMounts = nasMount "/var/lib/prometheus2" "prometheus"
    // nasMount "/var/lib/loki" "loki"
    // nasMount pyroscopeDir "pyroscope"
    // nasMountRo appImportsMount telemetry.appDashboardsShare;

  # sqlite on nfs corrupts; local, the nas keeps a nightly copy
  homelab.localState.grafana = {
    path = "/var/lib/grafana";
    share = "grafana";
    unit = "grafana";
    sqlite = [ "data/grafana.db" ];
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

  # loki: logs from promtail on every vm
  services.loki = {
    enable = true;
    configuration = {
      # each app is its own tenant (its shipper says which), the lab another (the door below says so)
      auth_enabled = true;
      server = { http_listen_address = "127.0.0.1"; http_listen_port = ports.lokiLocal; };
      querier.multi_tenant_queries_enabled = true;
      runtime_config.file = lokiOverrides;
      server.grpc_listen_port = lokiGrpcPort;
      common = {
        instance_addr = "127.0.0.1";
        ring.kvstore.store = "inmemory";
        replication_factor = 1;
        path_prefix = "/var/lib/loki";
      };
      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = { prefix = "index_"; period = "24h"; };
      }];
      storage_config.filesystem.directory = "/var/lib/loki/chunks";
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config = {
        retention_period = observabilityRetention;
        volume_enabled = true;
        reject_old_samples = false;
        max_entries_limit_per_query = lokiMaxLines;
        # per tenant: an app's budget (the lab's own in lokiOverrides); lines past the limit are cut, not dropped
        ingestion_rate_mb = mibOf (limits.tenant.logLinesPerSecond * limits.tenant.logLineBytes);
        ingestion_burst_size_mb = mibOf (limits.tenant.logBurstLines * limits.tenant.logLineBytes);
        max_line_size = limits.tenant.logLineBytes;
        max_line_size_truncate = true;
      };
    };
  };

  # tempo: otlp tracing
  services.tempo = {
    enable = true;
    settings = {
      server = { http_listen_port = ports.tempo; grpc_listen_port = tempoGrpcPort; };
      # each app is its own tenant (X-Scope-OrgID, injected by swarm-render.py) with its own budget below
      multitenancy_enabled = true;
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:${toString ports.otlpGrpc}";
        http.endpoint = "0.0.0.0:${toString ports.otlpHttp}";
      };
      ingester.lifecycler.ring = { replication_factor = 1; kvstore.store = "inmemory"; };
      storage.trace = {
        backend = "local";
        local.path = "/var/lib/tempo/traces";
        wal.path = "/var/lib/tempo/wal";
      };
      # rate, errors and duration per span plus the service graph, as prometheus series with trace exemplars
      metrics_generator = {
        registry = { external_labels.source = "tempo"; inject_tenant_id_as = tenantLabel; };
        storage = {
          path = "/var/lib/tempo/generator/wal";
          remote_write = [{ url = "http://127.0.0.1:${toString ports.prometheusLocal}/api/v1/write"; send_exemplars = true; }];
        };
        # local-blocks backs traceql metrics queries in grafana
        traces_storage.path = "/var/lib/tempo/generator/traces";
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

  # pyroscope: continuous profiles, the nas holds them like loki's chunks
  users.users.pyroscope = { isSystemUser = true; group = "pyroscope"; };
  users.groups.pyroscope = { };
  systemd.services.pyroscope = {
    description = "Grafana Pyroscope continuous profiling";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = [ pyroscopeDir ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " ([
        "${pkgs.pyroscope}/bin/pyroscope"
        "-server.http-listen-port=${toString ports.pyroscope}"
        "-server.grpc-listen-port=${toString pyroscopeGrpcPort}"
        "-memberlist.bind-port=${toString pyroscopeMemberlistPort}"
      ] ++ map (flag: "-${flag}=${pyroscopeRingAddr}") pyroscopeRings ++ [
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
    "d /var/lib/tempo 0750 tempo tempo -"
    "d /var/lib/loki 0750 loki loki -"
    "d ${pyroscopeDir} 0750 pyroscope pyroscope -"
    # its disk retention check fails on a missing data dir until the first profile arrives
    "d ${pyroscopeDir}/data 0750 pyroscope pyroscope -"
  ];

  # localhost only, unauthenticated prober
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
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
    listenAddress = "127.0.0.1";
    port = ports.prometheusLocal;
    retentionTime = prometheusRetentionTime;
    extraFlags = [
      "--storage.tsdb.retention.size=${prometheusRetentionSize}"
      # tempo's metrics generator pushes span metrics here, over loopback
      "--web.enable-remote-write-receiver"
      # the trace ids on those span metrics, for grafana's exemplar links
      "--enable-feature=exemplar-storage"
      # the browsers' metrics, through the frontend intake below, over loopback
      "--web.enable-otlp-receiver"
    ];
    scrapeConfigs = [
      {
        # tsdb size and block bytes, for the retention size cap; the watchdog's signal
        job_name = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString ports.prometheusLocal}" ]; }];
      }
      {
        # the monitoring stack's own health: ingestion, drops, rings
        job_name = "monitoring";
        static_configs = map (c: {
          targets = [ "127.0.0.1:${toString c.port}" ];
          labels = { component = c.name; vm = vmName collector; };
        }) [
          { name = "loki"; port = ports.loki; }
          { name = "tempo"; port = ports.tempo; }
          { name = "pyroscope"; port = ports.pyroscope; }
          { name = "grafana"; port = ports.grafana; }
          { name = "promtail"; port = promtailPort; }
        ];
      }
      {
        # standard blackbox relabel; `vm` gates the alert on the guest being up
        job_name = "blackbox-http";
        metrics_path = "/probe";
        params.module = [ "http_up" ];
        scrape_interval = "60s";
        static_configs = map (p: {
          targets = [ p.url ];
          labels = { service = p.name; inherit (p) vm; };
        }) probes;
        relabel_configs = probeRelabels;
      }
      {
        # sccache speaks redis, not http, and every tcp route the router forwards
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params.module = [ "tcp_up" ];
        scrape_interval = "60s";
        static_configs = map (p: { targets = [ p.target ]; labels = { service = p.name; inherit (p) vm; }; })
          ([ { name = "sccache"; vm = vmName sccache; target = "${sccache.ip}:${toString sccachePort}"; } ] ++ l4Probes);
        relabel_configs = probeRelabels;
      }
      {
        job_name = nodeJob;
        relabel_configs = vmRelabels;
        static_configs = [{
          # the inventory, not a sweep of both /24s: 480 dead targets a minute bought nothing
          targets = lib.mapAttrsToList (_: v: nodeTarget v.ip) guestsScraped
            ++ lib.optional (router != null) (nodeTarget routerAddress)
            ++ [ (nodeTarget site.lan.proxmox) ];
        }];
      }
      {
        # traefik metrics on both ingresses
        job_name = "traefik";
        static_configs = [{
          targets = [ "${internalIngress.ip}:${toString traefikMetricsPort}" edgeTraefikTarget ];
        }];
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
        static_configs = [{ targets = [ "${(guest (toString homeAssistant.vmid)).ip}:${toString homeAssistant.port}" ]; }];
      }
    ] ++ exporterScrapeConfigs ++ appScrapeConfigs;
    # the hass token file only exists at runtime
    checkConfig = "syntax-only";
    # grafana unified alerting owns every rule
  };

  # prometheus' query api for the lan, reads only: no lan device may forge a backup timestamp or a meter reading
  services.nginx = {
    enable = true;
    # loki's door: a sender or reader that names no tenant (promtail on the lab hosts, stats-sync) is the lab
    appendHttpConfig = ''
      map $http_x_scope_orgid $loki_tenant { "" "${telemetry.labTenant}"; default $http_x_scope_orgid; }
    '';
    virtualHosts.loki = {
      listen = [{ addr = "0.0.0.0"; port = ports.loki; }];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString ports.lokiLocal}";
        extraConfig = "proxy_set_header X-Scope-OrgID $loki_tenant;";
      };
    };
    virtualHosts.prometheus-read = {
      listen = [{ addr = "0.0.0.0"; port = ports.prometheus; }];
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString ports.prometheusLocal}";
        # GET covers HEAD; the ui and every api read
        extraConfig = "limit_except GET { deny all; }";
      };
      # long queries are a form POST; still reads
      locations."~ ^/api/v1/(query|query_range|query_exemplars|series|labels|label/[^/]+/values)$" = {
        proxyPass = "http://127.0.0.1:${toString ports.prometheusLocal}";
        extraConfig = "limit_except GET POST { deny all; }";
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
      install -m 400 -o prometheus -g prometheus \
        "$(test -s ${config.homelab.tokens.dir}/hass-key.token && echo ${config.homelab.tokens.dir}/hass-key.token || echo /dev/null)" \
        ${hassScrapeToken}
    '';
  };

  # nfs state stops slowly, 45s default killed them
  systemd.services.prometheus.serviceConfig = {
    TimeoutStopSec = "5min";
    # upstream sets Restart already, so override
    Restart = lib.mkForce "on-failure";
    RestartSec = 10;
  };
  systemd.services.grafana.serviceConfig = {
    TimeoutStopSec = "2min";
    Restart = lib.mkForce "on-failure";
    RestartSec = 10;
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = ports.grafana;
        root_url = "https://grafana.${domain}";
      };
      # gated by authelia forwardauth
      auth = {
        disable_login_form = true;
      };
      "auth.anonymous".enabled = false;
      "auth.proxy" = {
        enabled = true;
        header_name = "Remote-User";
        header_property = "username";
        auto_sign_up = true;
        # homepage and hermes reach :80 too, and a user header from them is no login
        whitelist = "${internalIngress.ip}, 127.0.0.1";
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
        # one tempo and one pyroscope per tenant replaced the lab-wide ones
        deleteDatasources = [ { name = "Tempo"; orgId = 1; } { name = "Pyroscope"; orgId = 1; } ];
        datasources = tenantDatasources ++ [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:${toString ports.prometheusLocal}";
            uid = "prometheus";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:${toString ports.lokiLocal}";
            uid = "loki";
            jsonData = lokiJsonData // { httpHeaderName1 = telemetry.tenantHeader; };
            secureJsonData.httpHeaderValue1 = lokiTenants;
          }
        ];
      };
      dashboards.settings = {
        providers = [
          {
            name = "Default";
            options.path = "/etc/grafana-dashboards";
          }
          # one folder per app, holding its generated board and, from the share, the boards it ships
          { name = "Apps"; options = { path = "/etc/${appBoardsDir}"; foldersFromFilesStructure = true; }; }
          {
            name = "App boards";
            updateIntervalSeconds = appImportScanS;
            options = { path = "${appImportsMount}/${telemetry.appDashboardsDir}"; foldersFromFilesStructure = true; };
          }
        ];
      };
      # alerting always on, delivers to ntfy
      alerting = {
        # rendered by sops with secrets filled
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
              # the heartbeat goes nowhere else, every heartbeatInterval
              {
                receiver = "heartbeat";
                object_matchers = [ [ "category" "=" "heartbeat" ] ];
                group_wait = "0s";
                group_interval = "1m";
                repeat_interval = heartbeatInterval;
                continue = false;
              }
            ] ++ lib.optional enableTelegram {
              receiver = "telegram";
              object_matchers = [ [ "notify" "=" "telegram" ] ];
              continue = true;
            } ++ [ { receiver = "ntfy"; } ];
          }];
        };
        rules.settings = {
          apiVersion = 1;
          deleteRules = map (uid: { orgId = 1; inherit uid; }) retiredRules;
          groups = [{
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = map mkRule rules;
          }];
        };
      };
    };
  };

  environment.etc = lib.mapAttrs' (name: board: lib.nameValuePair "grafana-dashboards/${name}.json" { source = board; })
    dashboards
    // lib.mapAttrs' (key: board: lib.nameValuePair "${appBoardsDir}/${boardFolderOf key}/service-${key}.json" { source = board; })
      serviceDashboards;

  # file provider rescans only at startup
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
    script = "${spotPrice}/bin/spot-price ${spotPriceState}/spot.json ${textfileDir}/spot_price.prom";
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
      out=${textfileDir}/grafana_alerts.prom
      # no answer means no data, never a stale alert list
      if ! json=$(curl -sf -m10 -H 'Remote-User: admin' \
          'http://127.0.0.1:${toString ports.grafana}/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'); then
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

  networking.firewall.allowedTCPPorts = [
    ports.grafana ports.prometheus ports.loki ports.tempo ports.otlpGrpc ports.otlpHttp ports.pyroscope ports.journalRemote ports.otlpFrontend
  ];

  # grafana trusts Remote-User (auth.proxy); loki has auth off, promtail on the ingresses pushes
  homelab.ingressOnly.ports = [
    ports.grafana ports.prometheus ports.loki ports.tempo ports.otlpGrpc ports.otlpHttp ports.pyroscope ports.journalRemote ports.otlpFrontend
  ];
  homelab.ingressOnly.portSources = {
    # lab services send traces, the apps too, over either otlp transport
    ${toString ports.otlpGrpc} = labSources ++ lib.optionals (appsTelemetry != { }) appNodeSources;
    ${toString ports.otlpHttp} = labSources ++ lib.optionals (appsTelemetry != { }) appNodeSources;
    # the app servers push profiles; any node may run the server task
    ${toString ports.pyroscope} = lib.optionals (appsTelemetry != { }) appNodeSources;
    # the browsers' beacons, relayed by the ingresses from each app's origin
    ${toString ports.otlpFrontend} = [ (hostSource internalIngress) (hostSource edgeIngress) ];
    # read-only queries: the desktop widget on the lan, the feeds on vm-104
    ${toString ports.prometheus} = [ site.lan.subnet (hostSource terminal) ];
    # stats-sync on the terminal reads, the edge and the workers' shippers push
    ${toString ports.loki} = [ (hostSource terminal) (hostSource edgeIngress) ] ++ lib.optionals (appsEnabled != { }) appNodeSources;
    # every guest uploads its journal, the swarm nodes whether or not an app is enabled
    ${toString ports.journalRemote} = labSources ++ appNodeSources;
  };

  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
