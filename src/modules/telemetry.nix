# Where the lab's telemetry goes and how it is labeled, defined once for every host.
#
# collector, ports, urls: vm-105 collects metrics, logs, traces and profiles; its ports are named here and nowhere
# else, so 105-internal-grafana.nix listens on them and every sender (modules/base journal upload and promtail,
# the feeds on vm-104, the homepage on vm-103) addresses them.
#
# vmName: the readable `vm` label of a guest, "router" for the router. The short name of "134-internal-jellyfin" is "jellyfin"; when two
# guests share it, the zone tells them apart (traefik-internal, traefik-external), and when they share the zone
# too (the swarm workers), the id does (swarm-150). 105-internal-grafana.nix labels node-exporter targets with it,
# 104-internal-terminal.nix hands it to stats-sync.py through the inventory json, so Grafana and the TRMNL panel
# name a guest alike.
#
# swarmTaskPatterns: swarm names a task's container <stack>_<service>.<slot>.<task id>. The regexes cut the
# task id (a new one per deploy and restart) and derive service and stack. modules/base (promtail),
# modules/app-telemetry.nix (the workers' log shipper) and the cadvisor scrape in 105-internal-grafana relabel with
# the same ones.
#
# tenantOf: an app's own tenant in tempo and pyroscope, whose limits only that app's traces and profiles meet.
{ lib, inventory }:
let
  shortName = v:
    let m = builtins.match "[0-9]+-(internal|external|apps)-(.*)" v.name;
    in if m == null then v.name else builtins.elemAt m 1;
  countBy = key: lib.foldl' (acc: v: acc // { ${key v} = (acc.${key v} or 0) + 1; }) { } (lib.attrValues inventory);
  nameCounts = countBy shortName;
  zonedName = v: "${shortName v}-${v.type}";
  zonedCounts = countBy zonedName;
  vmId = v: lib.head (lib.splitString "-" v.name);
  collector = inventory.${collectorVmid} or (throw "modules/telemetry.nix: the inventory has no collector ${collectorVmid}");
  collectorVmid = "105";

  ports = {
    grafana = 80;
    # the read-only query api (nginx); prometheus itself listens on loopback only, on prometheusLocal, so its
    # remote-write receiver is no write path for the lan
    prometheus = 9090;
    prometheusLocal = 9091;
    # loki's door (nginx): lab senders and readers without a tenant get the lab's; loki itself on loopback, lokiLocal
    loki = 3100;
    lokiLocal = 3101;
    tempo = 3200;
    otlpGrpc = 4317;
    otlpHttp = 4318;
    # browsers' otlp/http, relayed by the ingresses from each app's own origin (<host>/otlp/), tenant set there
    otlpFrontend = 4319;
    pyroscope = 4040;
    journalRemote = 19532;
    # every promtail's own http server (modules/base): its metrics, scraped for dropped entries
    promtail = 9080;
  };
in {
  inherit collectorVmid ports;
  urls = {
    prometheus = "http://${collector.ip}:${toString ports.prometheus}";
    loki = "http://${collector.ip}:${toString ports.loki}";
    lokiPush = "http://${collector.ip}:${toString ports.loki}/loki/api/v1/push";
    journalUpload = "http://${collector.ip}:${toString ports.journalRemote}";
    otlpGrpc = "http://${collector.ip}:${toString ports.otlpGrpc}";
    otlpHttp = "http://${collector.ip}:${toString ports.otlpHttp}";
    frontendIntake = "http://${collector.ip}:${toString ports.otlpFrontend}";
    pyroscope = "http://${collector.ip}:${toString ports.pyroscope}";
  };

  vmName = v:
    if v.type == "router" then "router"
    else if nameCounts.${shortName v} == 1 then shortName v
    else if zonedCounts.${zonedName v} == 1 then zonedName v
    else "${shortName v}-${vmId v}";

  swarmTaskPatterns = {
    # <stack>_<service>.<slot>: one stream per slot, stable across deploys
    container = "([^.]+\\.[^.]+)\\.[^.]+";
    # <stack>_<service>
    service = "([^.]+)\\.[^.]+\\.[^.]+";
    # <stack>
    stack = "([^_.]+)_[^.]+\\.[^.]+\\.[^.]+";
  };

  # swarm-render.py injects it into every app; the prefix keeps apps apart from the lab's own tenant
  tenantHeader = "X-Scope-OrgID";
  tenantOf = app: "app-${app}";
  # an app sending traces or profiles: its containers reach the collector, and its tenant exists there
  sendsSignals = a: a.off.traces == null || a.off.profiles == null;
  # loki's name for everything stored before tenants existed, so the lab's history stays readable
  labTenant = "fake";

  # the browsers' otlp path on every app's own origin, which the ingresses route to the frontend intake as it is
  frontendPath = "/otlp";

  # the lab's overview board: vm-105 builds it (lib/dashboards/homelab.py), the desktop clients open it (lab.export)
  homelabDashboardUid = "homelab";

  # the boards an app ships: the deploy controller writes them to this nas share, vm-105 provisions them read-only
  appDashboardsShare = "app-dashboards";
  appDashboardsDir = "dashboards";
}
