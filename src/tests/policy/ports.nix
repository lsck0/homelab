# every published port of the enabled apps belongs to one app and one container port
#
# The routing mesh publishes a port on every apps node, the router opens the edge's set of them and the edge
# routes by them, so two apps on one port would reach each other's containers. Within one app a port may appear
# in several groups (a route and the metrics scraped on it, as wat's server) as long as it names the same service
# and target port. cadvisor runs on every node: no app may take its port either.
{ lib, appsCatalog, ... }:
let
  groups = [ "routes" "metrics" ];
  enabled = lib.filterAttrs (_: a: a.enable or false) appsCatalog.apps;

  # every published port of every enabled app as { port, owner, where }
  uses = lib.concatLists (lib.mapAttrsToList (app: a: lib.concatMap (group:
    lib.mapAttrsToList (key: p: {
      inherit (p) port;
      owner = "${app}/${p.service}:${toString p.targetPort}";
      where = "apps.${app}.${group}.${key}";
    }) (a.${group} or { })
  ) groups) enabled)
  ++ [ { port = appsCatalog.cadvisorPort; owner = "cadvisor"; where = "cadvisorPort"; } ];

  byPort = lib.groupBy (u: toString u.port) uses;
in
lib.concatLists (lib.mapAttrsToList (port: claims:
  lib.optional (lib.length (lib.unique (map (c: c.owner) claims)) > 1)
    "port ${port} is published for ${lib.concatMapStringsSep ", " (c: "${c.owner} (${c.where})") claims}"
) byPort)
