{ config, pkgs, lib, inventory, nasMount, site, ... }:
let


  # guests meant to run only: onDemand ones sleep and disabled ones are off on purpose; down now, up within 30d
  notRunningIps = lib.mapAttrsToList (_: v: v.ip) (lib.filterAttrs (_: v: v.enabled != "true") inventory);
  instanceDownExpr = "up{job=\"homelab-node-exporter\""
    + lib.optionalString (notRunningIps != []) ",instance!~\"(${lib.concatMapStringsSep "|" (ip: lib.replaceStrings [ "." ] [ "\\\\." ] ip) notRunningIps}):9100\""
    + "} == 0 and max_over_time(up{job=\"homelab-node-exporter\"}[30d:5m]) > 0";

  # persistent timers catch up within this of a wake; scrape history, since an lxc reports the host's boot time
  upForCatchUp = "min_over_time(up{job=\"homelab-node-exporter\"}[1h]) == 1";

  # readable `vm` label, not ip:port
  shortName = v:
    let m = builtins.match "[0-9]+-(internal|external|apps)-(.*)" v.name;
    in if m == null then v.name else builtins.elemAt m 1;
  countBy = key: lib.foldl' (acc: v: acc // { ${key v} = (acc.${key v} or 0) + 1; }) { } (lib.attrValues inventory);
  nameCounts = countBy shortName;
  zonedName = v: "${shortName v}-${v.type}";
  zonedCounts = countBy zonedName;
  # the zone tells traefik-internal from traefik-external; the swarm nodes share name and zone, so the id
  vmName = v:
    if nameCounts.${shortName v} == 1 then shortName v
    else if zonedCounts.${zonedName v} == 1 then zonedName v
    else "${shortName v}-${lib.head (lib.splitString "-" v.name)}";
  vmLabel = address: name: {
    source_labels = [ "__address__" ];
    regex = "${lib.replaceStrings [ "." ] [ "\\." ] address}:9100";
    target_label = "vm";
    replacement = name;
  };
  router = lib.findFirst (v: v.type == "router") null (lib.attrValues inventory);
  vmRelabels =
    [{ source_labels = [ "__address__" ]; regex = "([^:]+):.*"; target_label = "vm"; replacement = "$1"; }]
    ++ lib.mapAttrsToList (_: v: vmLabel v.ip (vmName v)) (lib.filterAttrs (_: v: v.type != "router") inventory)
    ++ lib.optional (router != null) (vmLabel "10.100.0.1" "router")
    ++ [ (vmLabel site.lan.proxmox "proxmox") ];

  # blackbox probes
  # probe backends, public names always 302 via authelia
  routes = import ../modules/routes.nix;
  probes =
    let
      # on-demand/disabled vms would alarm forever
      alwaysOn = r: (inventory.${toString r.vmid}.enabled or "false") == "true"
        && (r.monitor or true);
      ofSide = side: lib.mapAttrsToList (name: r: {
        inherit name;
        url = "http://${inventory.${toString r.vmid}.ip}:${toString r.port}${r.health or ""}";
      }) (lib.filterAttrs (_: alwaysOn) side);
    in
    lib.concatLists (lib.mapAttrsToList (_: ofSide) routes)
    # the ingresses own no route
    ++ [
      { name = "traefik-internal"; url = "http://10.100.0.100:80"; }
      { name = "traefik-external"; url = "http://10.200.0.200:80"; }
    ];

  # app stacks (apps.nix): scraped, traced, profiled and alerted on here; a disabled app leaves none of it
  appsConfig = import ../modules/apps.nix;
  # the same view of the apps the ingresses and the router route by
  appsEnabled = (import ../modules/catalog.nix { inherit inventory lib; }).apps;
  appsTelemetry = lib.filterAttrs (_: a: a.telemetry or false) appsEnabled;
  appMetrics = a: a.metrics or { };
  appsWithMetric = name: lib.filterAttrs (_: a: appMetrics a ? ${name}) appsEnabled;
  # the swarm workers, any zone that types its guests "apps"; any of them may run any task, the manager none
  appNodes = lib.sort (a: b: lib.toInt (vmId a) < lib.toInt (vmId b))
    (lib.attrValues (lib.filterAttrs (_: v: v.type == "apps" && v.enabled == "true") inventory));
  vmId = v: lib.head (lib.splitString "-" v.name);
  # the routing mesh publishes every app port on every node: one node, or each sample counts once per node
  appScrapeNode =
    if appNodes == [ ] then throw "apps.nix enables an app, but inventory.json has no enabled guest of type apps"
    else lib.head appNodes;
  appNodeSources = map (v: "${v.ip}/32") appNodes;
  # the template's dashboards rate over [1m], four samples at 15s; the lab default of 1m leaves one
  appScrapeInterval = "15s";
  appTargetLabels = node: app: { inherit app; vm = vmName node; };
  # swarm names a task's container <stack>_<service>.<slot>.<task id>; same patterns as promtail in base.nix
  swarmServicePattern = "([^.]+)\\.[^.]+\\.[^.]+";
  swarmStackPattern = "([^_.]+)_[^.]+\\.[^.]+\\.[^.]+";
  appScrapeConfigs = lib.concatLists (lib.mapAttrsToList (app: a: lib.mapAttrsToList (name: m: {
    job_name = "app-${app}-${name}";
    scrape_interval = appScrapeInterval;
    metrics_path = m.path;
    static_configs = [{
      targets = [ "${appScrapeNode.ip}:${toString m.port}" ];
      labels = appTargetLabels appScrapeNode app;
    }];
  }) (appMetrics a)) appsEnabled)
  ++ lib.optional (appsEnabled != { }) {
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
      { source_labels = [ "name" ]; regex = swarmServicePattern; target_label = "swarm_service"; }
      { source_labels = [ "name" ]; regex = swarmStackPattern; target_label = "swarm_stack"; }
    ];
  };

  # the public ingress's metrics; vm-100 names its internal app routes the same way
  edgeTraefikTarget = "10.200.0.200:8082";
  # catalog.nix names an app's routes, and so the edge's services, <app> or <app>-<path slug>
  appTraefikServices = app: "${app}(-[a-z0-9-]+)?@file";
  appTraefikSelector = apps:
    "instance=\"${edgeTraefikTarget}\",service=~\"(${lib.concatMapStringsSep "|" appTraefikServices (lib.attrNames apps)})\"";
  # a client bug's steady trickle stays under 5%, a broken backend does not
  app5xxPercent = 5;
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

  # pyroscope: profiles pushed by the app servers (the template's rust agent)
  pyroscopePort = 4040;
  # tempo holds grpc 9095, loki 9096
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
  # the same horizon as loki's 336h, so a profile never outlives the logs around it
  pyroscopeRetention = "336h";

  # loki's default 5000 cut the template's log panels short
  lokiMaxLines = 10000;
  # the template's datasource timeout: 7d and 30d unique-visitor queries parse every access log line
  lokiQueryTimeoutSeconds = 60;

  # disks: ext4 data filesystems; /nix/store is a bind of / and would double every alert
  diskSelector = "fstype=\"ext4\",mountpoint!=\"/nix/store\"";
  diskUsedPercent = selector:
    "100 * (1 - node_filesystem_avail_bytes{${selector}} / node_filesystem_size_bytes{${selector}})";
  # a 3d trend smooths nightly dumps and gc; two weeks is time to order a disk or clean up
  diskForecastWindow = "3d";
  diskForecastHorizonSeconds = 14 * 86400;
  # vm-109's root sits on the proxmox thin pool, overcommitted until the pool is measured
  nasVmid = "109";
  nasRootPercent = 60;
  thinpoolDataWarnPercent = 80;
  thinpoolDataCriticalPercent = 90;
  # metadata exhaustion corrupts every thin volume at once, so it warns earlier than data
  thinpoolMetadataPercent = 70;

  prometheusPort = 9090;
  # energy history is the long-lived data, ~1GB a month; the nas data pool is shared with every guest's
  # state, so this cap, not the 10y, ends the history once it is reached
  prometheusRetentionSize = "50GB";

  # alerts also go to hermes telegram
  enableTelegram = true;

  # ntfy (vm-203) requires a login
  ntfyAlertTopic = "homelab-alerts";

  # ntfy renders go templates on the webhook body
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL "{{if eq .status \"firing\"}}FIRING{{else}}RESOLVED{{end}}: {{.commonLabels.alertname}}"}"
    "message=${lib.escapeURL "{{range .alerts}}{{.labels.vm}}{{if .annotations.summary}} - {{.annotations.summary}}{{end}}\n{{end}}"}"
    "tags=${lib.escapeURL "rotating_light"}"
  ];

  # one header per category and one line per alert; html-escaped, an unescaped "<id>" once made
  # telegram reject every message with 400
  telegramMessage = ''
    {{ if .Alerts.Firing }}🔴 <b>{{ .CommonAnnotations.firing | html }}</b>
    {{ range .Alerts.Firing }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}{{ if .Alerts.Resolved }}✅ <b>{{ .CommonAnnotations.resolved | html }}</b>
    {{ range .Alerts.Resolved }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}'';

  # grafana-managed rule, one query A thresholded by C
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
    # prometheus and loki restarting (a reboot, a deploy) is not every rule firing at once with empty labels
    execErrState = "KeepLast";
    labels = { severity = r.severity or "critical"; } // lib.optionalAttrs (r.telegram or true) { notify = "telegram"; };
    annotations = { inherit (r) firing resolved summary description; };
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
          url = "https://ntfy.lsck0.dev/${ntfyAlertTopic}?${ntfyQuery}";
          httpMethod = "POST";
          # ntfy denies anonymous publishing
          username = "grafana";
          password = config.sops.placeholder.ntfy-grafana-password;
        };
        disableResolveMessage = false;
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

  # inverter solar api, polled per scrape
  froniusExporter = pkgs.writers.writePython3Bin "fronius-exporter" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/fronius-exporter.py);
  froniusListen = "127.0.0.1:9118";
  # a site without a fronius inverter (site.json) has no house power data
  inverter = site.lan.inverter != "";
  # local copy: a missing nas token must fail one scrape, not prometheus
  hassScrapeToken = "/run/prometheus-hass/token";

  # generated, so the json cannot drift from the queries in energy.py
  energyDashboard = pkgs.runCommand "energy.json" { } ''
    ${pkgs.python3}/bin/python3 ${../modules/dashboards/energy.py} $out
  '';

  domain = "lsck0.dev";
  # the public ingress; its promtail labels the access log with this host
  edgeHost = "vm-200";
  # one board per enabled webapp-template stack, the ones exporting the template's server metrics
  webappDashboards = lib.mapAttrs (app: a: pkgs.runCommand "${app}.json" {
    config = builtins.toJSON {
      inherit app;
      requestHost = "${a.host}.${domain}";
      inherit edgeHost;
      traefikServices = appTraefikServices app;
      inherit edgeTraefikTarget;
      inherit traefikRateWindow;
    };
    passAsFile = [ "config" ];
  } ''
    ${pkgs.python3}/bin/python3 ${../modules/dashboards/webapp.py} "$configPath" $out
  '') (appsWithMetric "server");

  spotPrice = pkgs.writers.writePython3Bin "spot-price" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/spot-price.py);
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

  fileSystems = nasMount "/var/lib/prometheus2" "prometheus"
    // nasMount "/var/lib/loki" "loki"
    // nasMount pyroscopeDir "pyroscope";

  # sqlite on nfs corrupts; local, the nas keeps a nightly copy
  homelab.localState.grafana = {
    path = "/var/lib/grafana";
    share = "grafana";
    unit = "grafana";
    sqlite = [ "data/grafana.db" ];
  };

  # every host uploads its journal here (base.nix); promtail forwards to loki
  # journal-remote ignores MaxUse for the received files, so they outgrew the disk
  systemd.services.journal-remote-vacuum = {
    description = "Cap received journals at 1G";
    startAt = "hourly";
    serviceConfig.Type = "oneshot";
    script = "${config.systemd.package}/bin/journalctl --directory=/var/log/journal/remote --vacuum-size=1G";
  };

  services.journald.remote = {
    enable = true;
    listen = "http";
    port = 19532;
    # loki is the long-term store, this is a buffer
    settings.Remote = { SplitMode = "host"; MaxUse = "1G"; };
  };

  # loki: logs from promtail on every vm
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = 3100;
      # tempo already holds grpc 9095
      server.grpc_listen_port = 9096;
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
        retention_period = "336h"; # 14 days
        volume_enabled = true;
        reject_old_samples = false;
        max_entries_limit_per_query = lokiMaxLines;
      };
    };
  };

  # tempo: otlp tracing
  services.tempo = {
    enable = true;
    settings = {
      server.http_listen_port = 3200;
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:4317";
        http.endpoint = "0.0.0.0:4318";
      };
      ingester.lifecycler.ring = { replication_factor = 1; kvstore.store = "inmemory"; };
      storage.trace = {
        backend = "local";
        local.path = "/var/lib/tempo/traces";
        wal.path = "/var/lib/tempo/wal";
      };
      # rate, errors and duration per span plus the service graph, as prometheus series with trace exemplars
      metrics_generator = {
        registry.external_labels.source = "tempo";
        storage = {
          path = "/var/lib/tempo/generator/wal";
          remote_write = [{ url = "http://127.0.0.1:${toString prometheusPort}/api/v1/write"; send_exemplars = true; }];
        };
        # local-blocks backs traceql metrics queries in grafana
        traces_storage.path = "/var/lib/tempo/generator/traces";
        # the template's setting: client and internal spans count too, not only server spans
        processor.local_blocks.filter_server_spans = false;
      };
      overrides.defaults.metrics_generator.processors = [ "service-graphs" "span-metrics" "local-blocks" ];
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
        "-server.http-listen-port=${toString pyroscopePort}"
        "-server.grpc-listen-port=${toString pyroscopeGrpcPort}"
        "-memberlist.bind-port=${toString pyroscopeMemberlistPort}"
      ] ++ map (flag: "-${flag}=${pyroscopeRingAddr}") pyroscopeRings ++ [
        "-pyroscopedb.data-path=${pyroscopeDir}/data"
        # single binary: the compactor needs a bucket to apply the retention to
        "-storage.backend=filesystem"
        "-storage.filesystem.dir=${pyroscopeDir}/shared"
        "-compactor.data-dir=${pyroscopeDir}/compactor"
        "-blocks-storage.bucket-store.sync-dir=${pyroscopeDir}/sync"
        "-compactor.blocks-retention-period=${pyroscopeRetention}"
        "-usage-stats.enabled=false"
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
    port = 9115;
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

  services.prometheus = {
    enable = true;
    retentionTime = "10y";
    extraFlags = [
      "--storage.tsdb.retention.size=${prometheusRetentionSize}"
      # tempo's metrics generator pushes span metrics here
      "--web.enable-remote-write-receiver"
      # the trace ids on those span metrics, for grafana's exemplar links
      "--enable-feature=exemplar-storage"
    ];
    scrapeConfigs = [
      {
        # tsdb size and block bytes, for the retention size cap
        job_name = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString prometheusPort}" ]; }];
      }
      {
        # standard blackbox relabel
        job_name = "blackbox-http";
        metrics_path = "/probe";
        params.module = [ "http_up" ];
        scrape_interval = "60s";
        static_configs = map (p: {
          targets = [ p.url ];
          labels.service = p.name;
        }) probes;
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ];
      }
      {
        # sccache speaks redis, not http
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params.module = [ "tcp_up" ];
        scrape_interval = "60s";
        static_configs = [{
          targets = [ "10.100.0.110:6379" ];
          labels.service = "sccache";
        }];
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ];
      }
      {
        job_name = "homelab-node-exporter";
        relabel_configs = vmRelabels;
        static_configs = [{
          # the inventory, not a sweep of both /24s: 480 dead targets a minute bought nothing
          targets =
            lib.mapAttrsToList (_: v: "${v.ip}:9100") (lib.filterAttrs (_: v: v.type != "router") inventory)
            ++ lib.optional (router != null) "10.100.0.1:9100"
            ++ [ "${site.lan.proxmox}:9100" ];
        }];
      }
      {
        # traefik metrics (:8082) on both ingresses
        job_name = "traefik";
        static_configs = [{
          targets = [ "10.100.0.100:8082" edgeTraefikTarget ];
        }];
      }
    ] ++ lib.optional inverter {
      # house power: pv, grid meter, battery
      job_name = "fronius";
      scrape_interval = "10s";
      static_configs = [{ targets = [ froniusListen ]; }];
    } ++ [
      {
        # gas and water readings typed in by hand
        job_name = "homeassistant";
        scrape_interval = "60s";
        metrics_path = "/api/prometheus";
        authorization.credentials_file = hassScrapeToken;
        static_configs = [{ targets = [ "10.100.0.125:80" ]; }];
      }
    ] ++ appScrapeConfigs;
    # the hass token file only exists at runtime
    checkConfig = "syntax-only";
    # grafana unified alerting owns every rule
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
        http_port = 80;
        root_url = "https://grafana.lsck0.dev";
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
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:9090";
            uid = "prometheus";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:3100";
            uid = "loki";
            jsonData = { maxLines = lokiMaxLines; timeout = lokiQueryTimeoutSeconds; };
          }
          {
            name = "Tempo";
            type = "tempo";
            access = "proxy";
            url = "http://127.0.0.1:3200";
            uid = "tempo";
            jsonData = {
              # span attributes onto the journal labels base.nix promtail sets; a span carries only some of them
              tracesToLogsV2 = {
                datasourceUid = "loki";
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
          {
            name = "Pyroscope";
            type = "grafana-pyroscope-datasource";
            access = "proxy";
            url = "http://127.0.0.1:${toString pyroscopePort}";
            uid = "pyroscope";
          }
        ];
      };
      dashboards.settings = {
        providers = [
          {
            name = "Default";
            options.path = "/etc/grafana-dashboards";
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
            group_by = [ "alertname" ];
            group_wait = "1m";
            group_interval = "15m";
            repeat_interval = "24h";
            # a matching child route stops the fallback to the root receiver, so ntfy needs its own route
            routes = lib.optional enableTelegram {
              receiver = "telegram";
              object_matchers = [ [ "notify" "=" "telegram" ] ];
              continue = true;
            } ++ [ { receiver = "ntfy"; } ];
          }];
        };
        rules.settings = {
          apiVersion = 1;
          # a rule dropped from the list below stays in grafana's db until deleted here
          deleteRules = map (uid: { orgId = 1; inherit uid; }) [ "ossec_alert" "crowdsec_burst" ];
          groups = [{
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = map mkRule ([
              # offline
              {
                uid = "instance_down";
                title = "Guest offline";
                expr = instanceDownExpr;
                op = "lt"; threshold = 1;
                firing = "Offline"; resolved = "Back online";
                summary = "{{ $labels.vm }}";
                description = "node-exporter has been unreachable for 5 minutes. Check `vm status <id>` and the guest's journal.";
              }
              {
                uid = "service_down";
                title = "Service not answering";
                expr = "probe_success";
                op = "lt"; threshold = 1;
                for = "10m";
                firing = "Service down"; resolved = "Service back";
                summary = "{{ $labels.service }}";
                description = "The blackbox probe of the service's own port has failed for 10 minutes while its guest is up.";
              }
              # no backups taken
              {
                uid = "backup_stale";
                title = "NAS snapshot stale";
                expr = "time() - max(homelab_backup_last_success_timestamp_seconds{type=\"daily\"})";
                threshold = 26 * 3600;
                # missing data alerts too, but only once prometheus had time to scrape after a boot
                for = "30m";
                noData = "Alerting";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "NAS snapshot: none in over 26h";
                description = "Kopia on vm-109 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server`.";
              }
              {
                uid = "offsite_stale";
                title = "Off-site copy stale";
                expr = "time() - max(homelab_offsite_last_success_timestamp_seconds)";
                # a failed night is tolerated (proton's api fails runs now and then), plus start jitter and run length
                threshold = 60 * 3600;
                for = "30m";
                noData = "Alerting";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "Off-site (Proton Drive): no upload in over 60h";
                description = "proton-sync on vm-109 has not finished. Check `journalctl -u proton-sync`.";
              }
              {
                uid = "db_dump_stale";
                title = "Database dump stale";
                expr = "(time() - max by (vm, db) (homelab_db_dump_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
                threshold = 26 * 3600;
                for = "0m";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "{{ $labels.db }} dump on {{ $labels.vm }}: none in over 26h";
                description = "The nightly db-backup-<name> unit on that guest failed; the snapshot then holds only a live copy.";
              }
              {
                uid = "state_mirror_stale";
                title = "Local state mirror stale";
                expr = "(time() - max by (vm, state) (homelab_local_state_mirror_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
                threshold = 26 * 3600;
                for = "0m";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "{{ $labels.state }} mirror on {{ $labels.vm }}: none in over 26h";
                description = "The nightly <name>-mirror unit on that guest failed; the NAS copy, and with it the snapshot, is behind the guest's disk.";
              }
              # attacks
              {
                uid = "attack_flood";
                title = "Traffic flood";
                # crowdsec blocks background scans all day (tens/hour); only a real flood, orders of
                # magnitude over baseline, is worth waking for. sustained, so a brief spike is ignored.
                expr = "sum(rate(traefik_entrypoint_requests_total{entrypoint=\"websecure\"}[5m]))";
                threshold = 50;
                for = "15m";
                severity = "warning";
                firing = "Traffic flood"; resolved = "Flood over";
                summary = "{{ $values.A.Value | printf \"%.0f\" }} req/s sustained 15m: possible DoS";
                description = "Requests are far above baseline for 15 minutes. CrowdSec blocks known-bad; check `cscli metrics` and top talkers on vm-200. Routine scans do not trigger this.";
              }
              {
                uid = "sso_bruteforce";
                title = "Failed SSO logins";
                datasource = "loki";
                range = 900;
                # one failed login a week is normal
                expr = "sum(count_over_time({unit=\"authelia-main.service\"} |= \"Unsuccessful 1FA\" [15m]))";
                threshold = 4;
                for = "0m";
                severity = "warning";
                firing = "Attack detected"; resolved = "Attack over";
                summary = "{{ $values.A.Value }} failed SSO logins in 15 minutes";
                description = "Authelia rejected these passwords; it bans a user after 3 tries in 2 minutes.";
              }
              # not urgent, ntfy only
              {
                uid = "media_quota";
                title = "Media quota almost full";
                expr = "100 * max(homelab_media_bytes) / max(homelab_media_quota_bytes)";
                threshold = 95;
                for = "1h";
                severity = "warning";
                telegram = false;
                firing = "Media quota almost full"; resolved = "Media quota ok";
                summary = "media and torrents at {{ printf \"%.0f\" $values.A.Value }}% of their quota";
                description = "Downloads and imports stop at the quota (109-internal-nas.nix mediaQuotaGiB). Let janitorr clean up, delete media, or raise the quota.";
              }
              {
                uid = "disk_full";
                title = "Disk almost full";
                expr = diskUsedPercent diskSelector;
                threshold = 90;
                for = "30m";
                severity = "warning";
                telegram = false;
                firing = "Disk almost full"; resolved = "Disk space ok";
                summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used";
                description = "A guest filesystem is over 90%. Old generations, journal or images usually; on the nas bulk disk or the download disk, media.";
              }
              {
                uid = "disk_critical";
                title = "Disk full";
                expr = diskUsedPercent diskSelector;
                threshold = 95;
                for = "10m";
                firing = "Disk full"; resolved = "Disk space ok";
                summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used";
                description = "Writes on this filesystem fail soon: databases stop, journals and downloads break. Free space now.";
              }
              {
                uid = "disk_fill_predicted";
                title = "Disk fills within two weeks";
                expr = "predict_linear(node_filesystem_avail_bytes{${diskSelector}}[${diskForecastWindow}], ${toString diskForecastHorizonSeconds})";
                op = "lt"; threshold = 0;
                # a trend, not a spike: nightly dumps and downloads come and go within hours
                for = "2h";
                severity = "warning";
                telegram = false;
                firing = "Disk filling up"; resolved = "Disk trend ok";
                summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: full within 14 days at the 3-day trend";
                description = "The free space trend of the last 3 days reaches zero within two weeks. Find what grows before it is full.";
              }
            ] ++ lib.optional (inventory ? ${nasVmid}) {
                uid = "nas_root_thinpool";
                title = "NAS root over its thin pool share";
                expr = diskUsedPercent "vm=\"${vmName inventory.${nasVmid}}\",mountpoint=\"/\"";
                threshold = nasRootPercent;
                for = "30m";
                severity = "warning";
                telegram = false;
                firing = "NAS root filling the thin pool"; resolved = "NAS root ok";
                summary = "vm-${nasVmid} /: {{ printf \"%.0f\" $values.A.Value }}% used";
                description = "vm-${nasVmid}'s root is a thin volume in an overcommitted pool; past ${toString nasRootPercent}% the pool, not the guest, may run out first. Lift this once homelab_thinpool_data_percent has history.";
            } ++ [
              # the proxmox host's textfile collector; no data until it exists
              {
                uid = "thinpool_data_warn";
                title = "Thin pool filling";
                expr = "homelab_thinpool_data_percent";
                threshold = thinpoolDataWarnPercent;
                for = "30m";
                severity = "warning";
                telegram = false;
                firing = "Thin pool filling"; resolved = "Thin pool ok";
                summary = "{{ $labels.vm }} thin pool data at {{ printf \"%.0f\" $values.A.Value }}%";
                description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Trim guests or grow the pool.";
              }
              {
                uid = "thinpool_data_critical";
                title = "Thin pool almost full";
                expr = "homelab_thinpool_data_percent";
                threshold = thinpoolDataCriticalPercent;
                for = "10m";
                firing = "Thin pool almost full"; resolved = "Thin pool ok";
                summary = "{{ $labels.vm }} thin pool data at {{ printf \"%.0f\" $values.A.Value }}%";
                description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Free space now: fstrim the guests, drop snapshots.";
              }
              {
                uid = "thinpool_metadata";
                title = "Thin pool metadata filling";
                expr = "homelab_thinpool_metadata_percent";
                threshold = thinpoolMetadataPercent;
                for = "10m";
                firing = "Thin pool metadata filling"; resolved = "Thin pool metadata ok";
                summary = "{{ $labels.vm }} thin pool metadata at {{ printf \"%.0f\" $values.A.Value }}%";
                description = "Full thin pool metadata corrupts the pool. Grow it with lvextend --poolmetadatasize.";
              }
              {
                uid = "app_target_down";
                title = "App metrics unreachable";
                expr = "up{job=~\"app-.*\"}";
                op = "lt"; threshold = 1;
                firing = "App down"; resolved = "App back";
                summary = "{{ $labels.job }} on {{ $labels.vm }}";
                description = "Prometheus has not reached this app exporter for 5 minutes: the stack service is down, crash looping or not published.";
              }
            ] ++ lib.optional (appsWithMetric "postgres" != { }) {
                uid = "app_postgres_down";
                title = "App database down";
                expr = "min by (app) (pg_up)";
                op = "lt"; threshold = 1;
                firing = "App database down"; resolved = "App database back";
                summary = "{{ $labels.app }} postgres";
                description = "postgres_exporter answers but cannot reach postgres. Check the stack's postgres service on the apps nodes.";
            } ++ lib.optional (appsWithMetric "redis" != { }) {
                uid = "app_redis_down";
                title = "App cache down";
                expr = "min by (app) (redis_up)";
                op = "lt"; threshold = 1;
                firing = "App cache down"; resolved = "App cache back";
                summary = "{{ $labels.app }} redis";
                description = "redis_exporter answers but cannot reach redis. Check the stack's redis service on the apps nodes.";
            } ++ lib.optional (appsEnabled != { }) (
              let
                requests = filter: "sum by (service) (rate(traefik_service_requests_total{${appTraefikSelector appsEnabled}${filter}}[${traefikRateWindow}]))";
              in {
                uid = "app_5xx";
                title = "App answering 5xx";
                expr = "100 * (${requests ",code=~\"5..\""} / ${requests ""}) and on (service) (${requests ""} > ${app5xxMinRequestsPerSecond})";
                threshold = app5xxPercent;
                for = "10m";
                severity = "warning";
                firing = "App failing requests"; resolved = "App answering again";
                summary = "{{ $labels.service }}: {{ printf \"%.0f\" $values.A.Value }}% 5xx";
                description = "Over ${toString app5xxPercent}% of the requests traefik sends this app fail with 5xx. Check its server logs: {swarm_stack=\"<app>\"} in Loki.";
              }) ++ lib.optional (appsEnabled != { }) {
                uid = "app_restart_loop";
                title = "App container restart loop";
                # each restart is a new task container, so the distinct names seen in the window
                expr = "count by (swarm_service) (count_over_time(container_start_time_seconds{swarm_service!=\"\"}[${restartLoopWindow}]))";
                threshold = restartLoopTasks;
                for = "0m";
                severity = "warning";
                firing = "Container restart loop"; resolved = "Container stable";
                summary = "{{ $labels.swarm_service }}: {{ $values.A.Value }} tasks in ${restartLoopWindow}";
                description = "Swarm keeps replacing this service's task. `docker service ps --no-trunc <service>` on an apps node shows why.";
            } ++ lib.mapAttrsToList (app: _: {
                uid = "app_${app}_walg_stale";
                title = "${app} WAL-G backup stale";
                datasource = "loki";
                range = walgStaleSeconds;
                expr = "sum(count_over_time({swarm_service=\"${app}_${walgService}\"} |= \"${walgSuccessLine}\" [${toString walgStaleSeconds}s]))";
                op = "lt"; threshold = 1;
                for = "30m";
                # no success line in the window is no series at all
                noData = "Alerting";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "${app} postgres: no WAL-G base backup in over ${toString (walgStaleSeconds / 3600)}h";
                description = "The stack's wal-g loop has not logged a successful backup-push. Its log: {swarm_service=\"${app}_${walgService}\"} in Loki.";
            }) (appsWithMetric "postgres"));
          }];
        };
      };
    };
  };

  environment.etc = {
    # one board: map, http, system, logs
    "grafana-dashboards/homelab.json".source = ../modules/dashboards/homelab.json;
    # house power, gas and water
    "grafana-dashboards/energy.json".source = energyDashboard;
  } // lib.mapAttrs' (app: d: lib.nameValuePair "grafana-dashboards/${app}.json" { source = d; }) webappDashboards;

  # file provider rescans only at startup
  systemd.services.grafana.restartTriggers = [ ../modules/dashboards/homelab.json energyDashboard ]
    ++ lib.attrValues webappDashboards;

  # wholesale price beside the contract price, for the cost panels
  systemd.services.spot-price = {
    description = "Export the day-ahead spot price";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = "${spotPrice}/bin/spot-price /var/lib/node-exporter-textfile/spot_price.prom";
  };

  # quarter-hour slots
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

  # firing grafana alerts as a gauge, for readers that may not reach grafana (the desktop bar);
  # value is the start time, fingerprint keeps two alerts with equal labels apart
  systemd.services.grafana-alerts-export = {
    description = "Export firing Grafana alerts to Prometheus";
    after = [ "grafana.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      d=/var/lib/node-exporter-textfile
      out=$d/grafana_alerts.prom
      # no answer means no data, never a stale alert list
      if ! json=$(curl -sf -m10 -H 'Remote-User: admin' \
          'http://127.0.0.1:80/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'); then
        rm -f "$out"; exit 0
      fi
      {
        echo "# HELP homelab_alert_firing Start time of a firing Grafana alert."
        echo "# TYPE homelab_alert_firing gauge"
        echo "$json" | jq -r '
          def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          .[] | "homelab_alert_firing{alertname=\"\(.labels.alertname // "alert" | esc)\",target=\"\(.labels.vm // .labels.instance // "" | esc)\",severity=\"\(.labels.severity // "" | esc)\",summary=\"\(.annotations.summary // "" | esc)\",fingerprint=\"\(.fingerprint | esc)\"} \(.startsAt | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch now | floor)"'
      } > "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
  systemd.timers.grafana-alerts-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = "30s"; };
  };

  # 3100 loki, 3200 tempo, 4317/4318 otlp, 4040 pyroscope, 19532 journal-remote
  networking.firewall.allowedTCPPorts = [ 80 prometheusPort 3100 3200 4317 4318 pyroscopePort 19532 ];

  # grafana trusts Remote-User (auth.proxy); loki has auth off, promtail on the ingresses pushes
  homelab.ingressOnly.ports = [ 80 prometheusPort 3100 3200 4317 4318 pyroscopePort 19532 ];
  # lab services send traces, the app servers too (grpc only, the template's exporter is tonic)
  homelab.ingressOnly.portSources."4317" = [ "10.100.0.0/24" "10.200.0.0/24" ]
    ++ lib.optionals (appsTelemetry != { }) appNodeSources;
  homelab.ingressOnly.portSources."4318" = [ "10.100.0.0/24" "10.200.0.0/24" ];
  # the app servers push profiles; any node may run the server task
  homelab.ingressOnly.portSources.${toString pyroscopePort} = lib.optionals (appsTelemetry != { }) appNodeSources;
  # desktop status widget scrapes prometheus
  homelab.ingressOnly.portSources."9090" = [ site.lan.subnet "10.100.0.104/32" ];
  # stats-sync on the terminal queries loki, the external traefik pushes its access log
  homelab.ingressOnly.portSources."3100" = [ "10.100.0.104/32" "10.200.0.200/32" ];
  # every guest uploads its journal, the swarm nodes whether or not an app is enabled
  homelab.ingressOnly.portSources."19532" = [ "10.100.0.0/24" "10.200.0.0/24" ] ++ appNodeSources;


  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
