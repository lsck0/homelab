# the telemetry laws: who may read the lab's metrics and logs, and who names the tenant a write lands in
#
# - query apis: the stores listen on loopback; prometheus' and loki's query doors are guarded and admit internal
#   guests and the owner's devices only, never the house lan or a dmz or apps address
# - push doors: every request a push door passes carries the tenant the door chose by the sender's address, and an
#   app node's relay sets it on every request it passes; no client header reaches a store
# - access logs: a secret in a url (a feed token, a share link) is cut before the line is shipped to loki
{ lib, configs, inventory, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  telemetry = import ../../modules/telemetry.nix { inherit lib inventory; };
  inherit (telemetry) ports tenantHeader;
  collector = lib.findFirst (c: c.homelab.vmid or null == telemetry.collectorVmid) (throw "policy/telemetry.nix: no collector")
    (lib.attrValues configs);

  # the owner's devices, and the internal zone, which reaches everything by decision
  readers = [ "${net.wan.workstation}/32" net.wireguard.subnet ];
  readerAllowed = source: lib.elem source readers
    || (lib.hasSuffix "/32" source && net.cidrContains net.zones.internal.subnet (lib.removeSuffix "/32" source));

  queryLaw = lib.concatMap (name: let port = ports.${name}; in
    if !(lib.elem port collector.homelab.ingressOnly.ports) then [ "${name} (${toString port}) on the collector is not guarded" ]
    else map (source: "${name} (${toString port}) admits ${source}, which is neither an internal guest nor the owner's devices")
      (lib.filter (s: !readerAllowed s) (collector.homelab.ingressOnly.allowed.${toString port} or [ ])))
    [ "prometheus" "loki" ]
  ++ lib.optional (collector.services.prometheus.listenAddress != "127.0.0.1") "prometheus listens beyond loopback"
  ++ lib.optional (collector.services.loki.configuration.server.http_listen_address != "127.0.0.1") "loki listens beyond loopback"
  ++ lib.optional (collector.services.tempo.settings.server.http_listen_address != "127.0.0.1") "tempo listens beyond loopback";

  # every location of an nginx that forwards (proxy_pass, grpc_pass) sets the tenant header to the variable named
  passes = config: lib.concatLists (lib.mapAttrsToList (vhost: v: lib.mapAttrsToList (path: l: {
    where = "${vhost} ${path}";
    text = (l.extraConfig or "") + lib.optionalString ((l.proxyPass or null) != null) "proxy_pass ${l.proxyPass};";
  }) (v.locations or { })) config.services.nginx.virtualHosts);
  pushPorts = with ports; [ lokiPush otlpHttp otlpGrpc pyroscope ];
  pushVhosts = lib.filterAttrs (_: v: lib.any (l: lib.elem l.port pushPorts) (v.listen or [ ])) collector.services.nginx.virtualHosts;
  forwards = text: lib.hasInfix "proxy_pass" text || lib.hasInfix "grpc_pass" text;
  setsTenant = variable: text: lib.hasInfix "_set_header ${tenantHeader} ${variable};" text;
  doorLaw = lib.optional (pushVhosts == { }) "the collector has no push doors"
    ++ map (p: "push door ${p.where} forwards without the tenant its sender's address names")
      (lib.filter (p: forwards p.text && !(setsTenant "$push_tenant" p.text)) (passes { services.nginx.virtualHosts = pushVhosts; }));

  relayLaw = lib.concatLists (lib.mapAttrsToList (name: config:
    let locations = lib.tail (lib.splitString "location = " config.homelab.appTelemetry.relayConfig); in
    lib.optional (!(config.systemd.services ? app-relay)) "${name}: an app node without the relay"
    ++ lib.optional (locations == [ ]) "${name}: the relay passes nothing"
    ++ map (_: "${name}: a relay location forwards without the tenant of the sender's address")
      (lib.filter (l: forwards l && !(setsTenant "$tenant" l)) locations)
  ) (lib.filterAttrs (_: c: c.homelab.appTelemetry.enable or false) configs));

  # a url secret (a feed token, a share link) never reaches loki: each access log's shipper cuts it, and only it
  secretPaths = [ "/0123456789abcdef0123456789abcdef01234567/calendar.ics" "/feed?token=Zm9vYmFyYmF6cXV4cXV1eHF1dXhxdXV4cXV1eA" ];
  plainPaths = [ "/api/v1/status" "/assets/index-4f2a9c1b.js" ];
  redacts = expression: path: builtins.length (builtins.split expression path) > 1;
  accessLogLaw = lib.concatLists (lib.mapAttrsToList (name: config: let
    jobs = lib.filter (j: lib.any (c: (c.labels.__path__ or null) == config.homelab.traefik.accessLog) (j.static_configs or [ ]))
      config.services.promtail.configuration.scrape_configs;
    replaces = j: map (s: s.replace.expression) (lib.filter (s: s ? replace) (j.pipeline_stages or [ ]));
  in lib.optional (jobs == [ ]) "${name}: no shipper reads the access log" ++ lib.concatMap (j:
    map (p: "${name}: ${j.job_name} ships ${p} unredacted") (lib.filter (p: !(lib.any (e: redacts e p) (replaces j))) secretPaths)
    ++ map (p: "${name}: ${j.job_name} redacts the plain path ${p}") (lib.filter (p: lib.any (e: redacts e p) (replaces j)) plainPaths)
  ) jobs) (lib.filterAttrs (_: c: c.homelab.traefik.enable or false) configs));
in
map (v: "query api: ${v}") queryLaw ++ map (v: "push door: ${v}") doorLaw ++ map (v: "relay: ${v}") relayLaw
++ map (v: "access log: ${v}") accessLogLaw
