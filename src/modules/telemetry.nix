# where the lab's telemetry goes, how it is labeled, and the shape of an alert, defined once for every host
#
# security: senders address vm-103's push doors, which set the tenant from the sender's address and serve nothing
# else; the stores listen on loopback; readers get the query doors, each guarded to its named readers. App containers
# never reach vm-103: they send to the relay on their own node (modules/app-telemetry.nix).
# alertType: the uid is Grafana's id: a renamed uid loses the rule's history and silences, and the old rule stays in
# Grafana's database until it is deleted there.
{ lib, inventory }:
let
  inherit (lib) mkOption types;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  collectorVmid = lib.findFirst (id: lib.elem "collector" inventory.${id}.roles)
    (throw "modules/telemetry.nix: no guest holds the role collector") (lib.attrNames inventory);

  ports = {
    grafana = 80;
    # the read-only query door (nginx) of prometheus, which listens on prometheusLocal
    prometheus = 9090;
    prometheusLocal = 9091;
    # loki's query door and push door (nginx), loki itself on lokiLocal
    loki = 3100;
    lokiLocal = 3101;
    lokiPush = 3102;
    # tempo's query api, loopback only
    tempo = 3200;
    # the otlp and pyroscope push doors (nginx), and the stores behind them
    otlpGrpc = 4317;
    otlpHttp = 4318;
    otlpGrpcLocal = 14317;
    otlpHttpLocal = 14318;
    pyroscope = 4040;
    pyroscopeLocal = 14040;
    # browsers' otlp/http, relayed by the ingresses from each app's own origin (<host>/otlp/), tenant set there
    otlpFrontend = 4319;
    journalRemote = 19532;
    # every promtail's own http server: its metrics, scraped for dropped entries
    promtail = 9080;
  };

  # docker's default bridge address, the same on every node (modules/app-telemetry.nix pins it): a task reaches its
  # own node's relay there whatever node it runs on
  relayAddress = "172.17.0.1";
  relayBridge = "${relayAddress}/16";

  # the only requests a push door (vm-103) or a relay (an app node) passes, by the port it listens on
  pushPaths = {
    lokiPush = [ "/loki/api/v1/push" ];
    otlpHttp = [ "/v1/traces" ];
    otlpGrpc = [ "/opentelemetry.proto.collector.trace.v1.TraceService/Export" ];
    # the legacy ingest api (pyroscope-rs, the template's agent) and the connect push api (alloy)
    pyroscope = [ "/ingest" "/push.v1.PusherService/Push" ];
  };

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
    upstream = { firing = "Upstream unavailable"; resolved = "Upstream back"; };
    heartbeat = { firing = "Alerting alive"; resolved = "Alerting stopped"; };
  };

  # vm-103's probe of every third-party service (modules/upstream); upstreamUp <name> is 1 while it answers, so an
  # alert multiplied by it stays quiet through that service's own "unavailable" alert
  upstreamJob = "upstream";
  upstreamUp = name: "max(probe_success{job=\"${upstreamJob}\",upstream=\"${name}\"})";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  collector = inventory.${collectorVmid} or (throw "modules/telemetry.nix: the inventory has no collector ${collectorVmid}");
  urlOf = port: "http://${collector.ip}:${toString port}";

  shortName = v:
    let m = builtins.match "[0-9]+-(internal|external|apps)-(.*)" v.name;
    in if m == null then v.name else builtins.elemAt m 1;
  countBy = key: lib.foldl' (acc: v: acc // { ${key v} = (acc.${key v} or 0) + 1; }) { } (lib.attrValues inventory);
  nameCounts = countBy shortName;
  zonedName = v: "${shortName v}-${v.type}";
  zonedCounts = countBy zonedName;
  vmId = v: lib.head (lib.splitString "-" v.name);

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  alertType = types.submodule {
    options = {
      title = mkOption { type = types.str; description = "The rule's name in Grafana."; };
      category = mkOption { type = types.enum (lib.attrNames categories); description = "Groups notifications and names their header."; };
      expr = mkOption { type = types.str; description = "PromQL, or LogQL with datasource loki: query A."; };
      op = mkOption { type = types.enum [ "gt" "lt" ]; default = "gt"; description = "How A meets the threshold."; };
      threshold = mkOption { type = types.number; description = "Condition C: A op threshold fires."; };
      for = mkOption { type = types.str; default = "5m"; description = "How long the condition holds before it fires."; };
      noData = mkOption {
        type = types.enum [ "OK" "Alerting" ];
        default = "OK";
        description = "Alerting where silence itself is the failure (a backup timestamp, a log line).";
      };
      execErr = mkOption {
        type = types.enum [ "KeepLast" "OK" ];
        default = "KeepLast";
        description = "A store restarting is not every rule firing at once; OK where an error means silence is wanted.";
      };
      severity = mkOption { type = types.enum [ "warning" "critical" ]; default = "warning"; description = "critical: needs action today."; };
      telegram = mkOption { type = types.bool; default = false; description = "Pages over telegram besides ntfy."; };
      datasource = mkOption { type = types.enum [ "prometheus" "loki" ]; default = "prometheus"; description = "What A queries."; };
      rangeSeconds = mkOption { type = types.ints.positive; default = 600; description = "How far A looks back (loki rules)."; };
      summary = mkOption { type = types.str; description = "One line per alert; a go template over $labels and $values."; };
      description = mkOption { type = types.str; description = "What it means and the first command to run."; };
    };
  };
in {
  inherit collectorVmid ports categories alertType relayAddress relayBridge pushPaths upstreamJob upstreamUp;

  urls = {
    prometheus = urlOf ports.prometheus;
    loki = urlOf ports.loki;
    lokiPush = "${urlOf ports.lokiPush}/loki/api/v1/push";
    journalUpload = urlOf ports.journalRemote;
    otlpGrpc = urlOf ports.otlpGrpc;
    otlpHttp = urlOf ports.otlpHttp;
    pyroscope = urlOf ports.pyroscope;
    frontendIntake = urlOf ports.otlpFrontend;
  };

  # what an app's containers name as the lab's telemetry ({{homelab.*}}, modules/catalog.nix): their node's relay
  relayEndpoints = {
    otlp-grpc = "http://${relayAddress}:${toString ports.otlpGrpc}";
    otlp-http = "http://${relayAddress}:${toString ports.otlpHttp}";
    # host:port, what a tcp forwarder (socat) wants
    pyroscope = "${relayAddress}:${toString ports.pyroscope}";
  };

  # alerts keyed by uid, typed and defaulted like an instance's (rules vm-103 writes itself)
  alertsOf = alerts: (lib.evalModules {
    modules = [{ options.alerts = mkOption { type = types.attrsOf alertType; }; config = { inherit alerts; }; }];
  }).config.alerts;

  # the readable `vm` label: the short name ("jellyfin"), the zone added where two guests share it, the id where they
  # share the zone too (swarm-250); vm-103's targets and vm-114's stats-sync both name guests by it
  vmName = v:
    if v.type == "router" then "router"
    else if nameCounts.${shortName v} == 1 then shortName v
    else if zonedCounts.${zonedName v} == 1 then zonedName v
    else "${shortName v}-${vmId v}";

  # swarm names a task's container <stack>_<service>.<slot>.<task id>, a new task id per deploy and restart
  swarmTaskPatterns = {
    # <stack>_<service>.<slot>: one stream per slot, stable across deploys
    container = "([^.]+\\.[^.]+)\\.[^.]+";
    service = "([^.]+)\\.[^.]+\\.[^.]+";
    stack = "([^_.]+)_[^.]+\\.[^.]+\\.[^.]+";
  };

  # the stack label docker gives every task container, which names its app
  stackLabel = "com.docker.stack.namespace";

  # the prefix keeps the apps apart from the lab's own tenant
  tenantHeader = "X-Scope-OrgID";
  tenantOf = app: "app-${app}";
  # an app sending traces or profiles: its containers reach the relay, and its tenant exists on vm-103
  sendsSignals = a: lib.elem "traces" a.on || lib.elem "profiles" a.on;
  # loki's name for everything stored before tenants existed, so the lab's history stays readable; the lab's tenant
  # in every store
  labTenant = "fake";

  # the browsers' otlp path on every app's own origin, which the ingresses route to the frontend intake as it is
  frontendPath = "/otlp";

  # the lab's overview board: vm-103 builds it (lib/dashboards/homelab.py), the desktop clients open it (lab.export)
  homelabDashboardUid = "homelab";

  # the boards an app ships: the deploy controller writes them to this nas share, vm-103 provisions them read-only
  appDashboardsShare = "app-dashboards";
  appDashboardsDir = "dashboards";
}
