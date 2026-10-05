# every route in the lab, one shape for the ingresses, the router, authelia and the prober:
# the nixos services of routes.nix (a vm and a port) and the swarm apps of apps.nix (the nodes and a published
# port, one route per url prefix). Read this, not the two files, wherever routes are consumed.
{ inventory, lib }:
let
  routes = import ./routes.nix;
  appsCatalog = import ./apps.nix;
  apps = lib.filterAttrs (_: a: a.enable or false) appsCatalog.apps;

  # the routing mesh answers on every node
  nodes = lib.sort (a: b: a < b) (map (v: v.ip)
    (lib.filter (v: v.type == "apps" && v.enabled != "false") (lib.attrValues inventory)));

  slug = prefix: lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" prefix);
  routeName = app: prefix: if prefix == "/" then app else "${app}-${slug prefix}";

  appRoute = app: a: prefix: p: {
    host = a.host or app;
    inherit prefix app nodes;
    inherit (p) port;
    # an active check needs a path that answers 2xx: the root of an app, an explicit one elsewhere, else none
    health = p.health or (if prefix == "/" then "/" else null);
    # html gets the proof of work; apis, presigned files and other non-browser paths do not
    anubis = p.anubis or (prefix == "/");
    # the waf reads bodies: off where they are uploads
    waf = p.waf or true;
    # bytes, null: the edge's default
    bodyLimit = p.bodyLimit or null;
  };
in {
  inherit apps nodes;
  manager = inventory.${toString appsCatalog.swarm.manager};

  # internal: sso behind authelia on vm-100, unless auth says otherwise
  internal = routes.internal // lib.foldl' (acc: name: acc // lib.mapAttrs (host: p:
    (appRoute name apps.${name} "/" p) // { inherit host; }
  ) (apps.${name}.internal or { })) { } (lib.attrNames apps);

  # external: public behind the edge on vm-200
  external = routes.external // lib.foldl' (acc: name: acc // lib.listToAttrs (lib.mapAttrsToList (prefix: p:
    lib.nameValuePair (routeName name prefix) (appRoute name apps.${name} prefix p)
  ) (apps.${name}.paths or { }))) { } (lib.attrNames apps);
}
