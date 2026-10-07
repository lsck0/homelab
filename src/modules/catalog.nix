# every route in the lab, one shape for the ingresses, the router, authelia and the prober, plus the swarm's shape
#
# An instance service's route (modules/lab: a vm and a port) and a swarm app's route (src/apps/: the cluster's
# nodes and a published port) are the same exposure (modules/service.nix); here they meet, plus vmid (null for an
# app's), app (null for an instance's) and nodes (an app's cluster). modules/lab evaluates this once over the typed
# catalog (`lab.catalog`, its `problems` stopping the flake) and every host gets it as the argument `catalog`.
#
#   apps            the enabled apps, normalized by the schema, `{{homelab.*}}` endpoints resolved
#   internal        route name -> route served by vm-100, behind authelia unless its `off.sso` says why not
#   external        route name -> route served by the edge, vm-200
#   l4              route name -> tcp or udp route: forwarded from the house's publicPort, or lab-only without one
#   forwarded       the l4 routes the router forwards from the house's public address
#   access          { admins; groups.<name>; } the lldap groups authelia admits: admins everywhere, else the sso
#                   route's or the oidc client's own group; lldap creates exactly these
#   nodes           the shared swarm's workers' addresses: the routing mesh answers every published port on each
#   clusters        swarm name (`shared`, `app-<name>`) -> { managerId; workerIds; stateId; wakers; nodes; zone; apps;
#                   admission }: wakers the guests calling its controller (the ingresses, the state worker's dumps)
#   services        service key (an instance service or an app) -> { vmid; app; on.<feature>; metrics; idle; routes; ... }
#   manager         the swarm manager's inventory entry
#   builder         the app builder's inventory entry
#   swarm           { managerId; builderId; stateId; controllerPort; cadvisorPort; taskDefaults; ports; portRange; }
#   ports           { external; internal; metrics; tcp; udp; } the enabled apps' published ports by group: http by
#                   its zone, exporters, and the tcp and udp ports of l4 routes, which answer anyone
#   secretRefs      the sops secrets a string names as {{name}}
#   metricsBlocks   [{ app; host; path; }] metrics a public route would expose: the edge denies them
#   appsZone        the workers' subnet (cidr, modules/net.nix)
#   ingress         { internal; external; } the inventory entries of the two ingresses (modules/net.nix zones)
#   probeUrlOf r    the url the prober and the status dots check an http route at
#   registry        the registry's name, which the builder pushes to and every stack's images name
#   problems        what breaks the lab-wide rules, one line each naming every side; empty when the catalog holds
#
# Rejected: merging the route sets with `//`. A later app silently replaced an earlier route of the same name, so
# `wat.internal.grafana` took grafana's authelia route; every collision is a problem instead.
{ inventory, lib, site, appsCatalog, lab }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  telemetry = import ./telemetry.nix { inherit lib inventory; };
  service = import ./service.nix { inherit lib; };
  limits = import ./limits { inherit lib; };
  net = import ./net.nix { inherit lib inventory site; };
  inherit (net) domain;
  # internal routes are served by the internal zone's ingress, external ones by the edge
  ingressIds = { internal = net.zones.internal.ingress; external = net.zones.external.ingress; };
  # swarm's control plane, its gossip, and the vxlan data path of the overlays
  swarmPorts = { manager = net.ports.swarmManager; gossip = net.ports.swarmGossip; vxlan = net.ports.vxlan; };
  # an app publishes a port for each http route by its zone, each l4 route by its protocol, and each exporter
  groups = [ "external" "internal" "metrics" "tcp" "udp" ];

  # `{{homelab.<name>}}` in an app's env or override: lab endpoints an app may not hard-code; all telemetry, at the
  # relay on the task's own node
  labEndpoints = telemetry.relayEndpoints;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  allApps = appsCatalog.apps;
  enabledRaw = lib.filterAttrs (_: a: a.enable) allApps;

  # the shared swarm's running workers; the routing mesh answers on each (an app's own guest is no worker)
  workerIds = lib.filter (id: inventory.${id}.powered) (map toString appsCatalog.swarm.workers);
  nodes = map (id: inventory.${id}.ip) workerIds;
  # a guest's shape as admission reads it (modules/limits allocatableOf)
  shapeOf = id: { inherit id; inherit (inventory.${id}) ip; inherit (lab.instances.${id}.config.vm) memoryMiB cores cpuLimitCores; };

  # every {{...}} of a string: secret refs, swarm templates ({{.Task.Slot}}), lab endpoints ({{homelab.x}})
  placeholdersOf = value: map lib.head (builtins.filter builtins.isList (builtins.split "\\{\\{([^}]*)}}" value));
  isSecretRef = inner: builtins.match "[a-z0-9][a-z0-9-]*" inner != null;
  isSwarmTemplate = inner: lib.hasPrefix "." inner;
  labRefOf = inner: let m = builtins.match "homelab\\.([a-z0-9-]+)" inner; in if m == null then null else lib.head m;
  secretRefs = value: builtins.filter isSecretRef (placeholdersOf value);
  labRefs = value: lib.filter (r: r != null) (map labRefOf (placeholdersOf value));

  resolveLab = value: builtins.replaceStrings
    (map (n: "{{homelab.${n}}}") (lib.attrNames labEndpoints)) (lib.attrValues labEndpoints) value;
  # every string of a nested value (an override is a compose overlay)
  strings = value:
    if builtins.isString value then [ value ]
    else if builtins.isList value then lib.concatMap strings value
    else if builtins.isAttrs value then lib.concatMap strings (lib.attrValues value)
    else [ ];
  resolveDeep = value:
    if builtins.isString value then resolveLab value
    else if builtins.isList value then map resolveDeep value
    else if builtins.isAttrs value then lib.mapAttrs (_: resolveDeep) value
    else value;
  envStrings = a: lib.concatMap lib.attrValues (lib.attrValues a.env);

  # where an app runs: the shared apps swarm, or its own guest, a swarm of one (its placement)
  clusterOf = a:
    if a.placement == null then { manager = toString appsCatalog.swarm.manager; inherit nodes; zone = "apps"; }
    else let id = toString a.placement.vmid; in { manager = id; nodes = [ inventory.${id}.ip ]; inherit (a.placement) zone; };

  normalize = a: a // {
    env = lib.mapAttrs (_: lib.mapAttrs (_: resolveLab)) a.env;
    override = resolveDeep a.override;
    cluster = clusterOf a;
  };
  apps = lib.mapAttrs (_: normalize) enabledRaw;

  # every swarm by name: `shared` (the workers of apps/swarm.nix, the apps without placement) and `app-<name>` per
  # app on its own guest, a swarm of one; admission (modules/limits) holds each to its own workers
  wakersOf = stateId: lib.unique (lib.attrValues ingressIds ++ [ stateId ]);
  sharedStateId = toString appsCatalog.swarm.state;
  clusters = {
    shared = {
      managerId = toString appsCatalog.swarm.manager;
      stateId = sharedStateId;
      wakers = wakersOf sharedStateId;
      inherit workerIds nodes;
      zone = "apps";
      apps = lib.filterAttrs (_: a: a.placement == null) apps;
    };
  } // lib.mapAttrs' (app: a: let id = toString a.placement.vmid; in lib.nameValuePair "app-${app}" {
    managerId = id;
    stateId = id;
    wakers = wakersOf id;
    workerIds = [ id ];
    inherit (a.cluster) nodes zone;
    apps.${app} = a;
  }) (lib.filterAttrs (_: a: a.placement != null) apps);
  admissionOf = c: limits.clusterOf {
    inherit (c) apps;
    workers = lib.genAttrs c.workerIds shapeOf;
    inherit (appsCatalog.swarm) taskDefaults;
  };

  # route name -> { name; owner; route; } for every route of the lab, so a collision can name both owners; an
  # instance service's route is its own exposure, an app's route runs on the app's cluster
  routeEntries = lib.mapAttrsToList (name: r: {
    inherit name;
    owner = "vm-${toString r.vmid}";
    route = r // { app = null; nodes = [ ]; };
  }) lab.routes
  ++ lib.concatLists (lib.mapAttrsToList (app: a: lib.mapAttrsToList (name: r: {
    inherit name;
    owner = "apps.${app}";
    route = r // { vmid = null; inherit app; inherit (a.cluster) nodes; };
  }) a.routes) apps);
  routesOf = zone: lib.listToAttrs (map (e: lib.nameValuePair e.name e.route)
    (lib.filter (e: e.route.protocol == "http" && e.route.zone == zone) routeEntries));
  l4Entries = lib.filter (e: e.route.protocol != "http") routeEntries;
  # what authelia guards: every http route with sso on, either ingress, and every oidc client
  ssoNames = map (e: e.name) (lib.filter (e: e.route.protocol == "http" && e.route.off.sso == null) routeEntries)
    ++ map (c: c.id) lab.oidc;

  # every published port of every enabled app as { port; owner; where; group; }
  uses = lib.concatLists (lib.mapAttrsToList (app: a:
    lib.mapAttrsToList (key: p: {
      inherit (p) port;
      group = if p.protocol == "http" then p.zone else p.protocol;
      owner = "${app}/${p.service}:${toString p.targetPort}";
      where = "apps.${app}.routes.${key}";
    }) a.routes
    ++ lib.mapAttrsToList (key: p: {
      inherit (p) port;
      group = "metrics";
      owner = "${app}/${p.service}:${toString p.targetPort}";
      where = "apps.${app}.metrics.${key}";
    }) a.metrics
  ) apps);

  # a metrics endpoint served by a container port that a public path also routes to is public unless denied
  metricsBlocks = lib.concatLists (lib.mapAttrsToList (app: a: lib.concatMap (m:
    map (r: { inherit app; inherit (r) host; inherit (m) path; })
      (lib.filter (r: r.protocol == "http" && r.zone == "external" && r.service == m.service && r.targetPort == m.targetPort) (lib.attrValues a.routes))
  ) (lib.attrValues a.metrics)) apps);

  # -----------------------------------------------------------------------------
  # PROBLEMS
  # -----------------------------------------------------------------------------

  inherit (appsCatalog.swarm) portRange taskMax;
  inRange = port: port >= portRange.first && port <= portRange.last;

  duplicatesBy = key: what: entries: lib.concatLists (lib.mapAttrsToList (k: es:
    lib.optional (lib.length (lib.unique (map (e: e.owner) es)) > 1)
      "${what} ${k} is claimed by ${lib.concatMapStringsSep " and " (e: e.owner) es}"
  ) (lib.groupBy key entries));

  # a host belongs to one owner, an instance or an app, whose routes split it by path
  hostOwners = map (e: { inherit (e) name owner; inherit (e.route) host; }) routeEntries;
  # the split horizon names a host at one ingress
  zoneProblems = lib.concatLists (lib.mapAttrsToList (host: es:
    lib.optional (lib.length (lib.unique (map (e: e.route.zone) es)) > 1) "host ${host}.${domain} is routed by both ingresses"
  ) (lib.groupBy (e: e.route.host) (lib.filter (e: e.route.protocol == "http") routeEntries)));
  hostProblems = lib.concatLists (lib.mapAttrsToList (host: es: let owners = lib.unique (map (e: e.owner) es); in
    lib.optional (lib.length owners > 1) "host ${host}.${domain} is claimed by ${lib.concatStringsSep " and " owners}"
  ) (lib.groupBy (e: e.host) hostOwners));

  portProblems = lib.concatLists (lib.mapAttrsToList (port: claims:
    lib.optional (lib.length (lib.unique (map (c: c.owner) claims)) > 1)
      "port ${port} is published for ${lib.concatMapStringsSep " and " (c: "${c.owner} (${c.where})") claims}"
  ) (lib.groupBy (u: toString u.port) uses))
  ++ map (u: "${u.where}.port ${toString u.port} is outside swarm.portRange ${toString portRange.first}-${toString portRange.last}")
    (lib.filter (u: !inRange u.port) uses)
  ++ lib.optional (inRange appsCatalog.cadvisorPort)
    "cadvisorPort ${toString appsCatalog.cadvisorPort} lies inside swarm.portRange, where an app may publish it"
  ++ lib.optional (lib.any (p: inRange p) (lib.attrValues swarmPorts))
    "swarm.portRange ${toString portRange.first}-${toString portRange.last} holds a port of swarm itself (${toString (lib.attrValues swarmPorts)})";

  appProblems = app: a: let
    where = "apps.${app}";
    envServices = lib.attrNames a.env;
    refs = lib.unique (lib.concatMap secretRefs (envStrings a));
    unknownPlaceholders = lib.unique (lib.filter (inner: !(isSecretRef inner || isSwarmTemplate inner || labRefOf inner != null))
      (lib.concatMap placeholdersOf (envStrings a ++ strings a.override)));
    lab = lib.unique (lib.concatMap labRefs (envStrings a ++ strings a.override));
    published = lib.unique (map (p: p.service) (lib.attrValues a.routes ++ lib.attrValues a.metrics));
  in
    lib.optional (builtins.match "[a-z][a-z0-9-]*" app == null) "${where}: an app name is [a-z][a-z0-9-]*, it names a stack and its routes"
    ++ map (s: "${where}.env names the secret {{${s}}}, which `secrets` does not generate: add `secrets.${s}`")
      (lib.subtractLists (lib.attrNames a.secrets) refs)
    ++ map (s: "${where}.secrets.${s} is named by no env value: remove it, or reference it as {{${s}}}")
      (lib.subtractLists refs (lib.attrNames a.secrets))
    ++ map (p: "${where}: {{${p}}} is neither a secret ({{name}}), a swarm template ({{.Task.Slot}}) nor a lab endpoint ({{homelab.${lib.concatStringsSep "|" (lib.attrNames labEndpoints)}}})")
      unknownPlaceholders
    ++ map (n: "${where}: {{homelab.${n}}} is no lab endpoint; known: ${lib.concatStringsSep ", " (lib.attrNames labEndpoints)}")
      (lib.subtractLists (lib.attrNames labEndpoints) lab)
    ++ lib.optional (lab != [ ] && a.off.traces != null && a.off.profiles != null)
      "${where} names {{homelab.*}} telemetry endpoints with traces and profiles off: the workers would drop its traffic"
    ++ map (d: "${where}.dumps.${d}.service ${a.dumps.${d}.service} is not stateful: a dump runs on the state worker only")
      (lib.filter (d: !(lib.elem a.dumps.${d}.service a.stateful)) (lib.attrNames a.dumps))
    ++ map (s: "${where}.exclude drops ${s}, which the catalog still uses (stateful, published, env or resources)")
      (lib.intersectLists a.exclude (a.stateful ++ published ++ envServices ++ lib.attrNames a.resources))
    ++ lib.optional (a.enable && a.routes == { } && a.metrics == { })
      "${where} publishes nothing: give it `routes` or `metrics`, or disable it"
    ++ lib.concatLists (lib.mapAttrsToList (service: r: map (limit:
      "${where}.resources.${service}.${limit} ${toString r.${limit}} is above swarm.taskMax.${limit} ${toString taskMax.${limit}}: a worker cannot hold it"
    ) (lib.filter (limit: r.${limit} > taskMax.${limit}) (lib.attrNames taskMax))) a.resources);
  # every deployment's telemetry and protection switches, by service key: an instance service (vmid) or an app
  services = lib.mapAttrs (name: r: {
    key = name;
    inherit (r) vmid zone;
    app = null;
    routes = [ name ];
    on = service.enabledOf r.off;
    inherit (lab.instances.${toString r.vmid}.config) idle;
    inherit (lab.instances.${toString r.vmid}.config.services.${name}) metrics;
  }) lab.routes // lib.mapAttrs (app: a: {
    key = app;
    vmid = null;
    inherit app;
    inherit (a) metrics idle cluster;
    routes = lib.attrNames a.routes;
    on = service.enabledOf a.off;
  }) apps;
in {
  inherit apps nodes domain metricsBlocks services secretRefs;
  # admission: limits.clusterOf over the cluster's workers
  clusters = lib.mapAttrs (_: c: c // { admission = admissionOf c; }) clusters;
  manager = inventory.${toString appsCatalog.swarm.manager};
  builder = inventory.${toString appsCatalog.builder};

  swarm = {
    managerId = toString appsCatalog.swarm.manager;
    builderId = toString appsCatalog.builder;
    stateId = sharedStateId;
    inherit (appsCatalog) controllerPort cadvisorPort;
    inherit (appsCatalog.swarm) taskDefaults;
    ports = swarmPorts;
    inherit portRange;
  };

  ports = lib.genAttrs groups (group: lib.unique (map (u: u.port) (lib.filter (u: u.group == group) uses)));

  appsZone = net.zones.apps.subnet;

  ingress = lib.mapAttrs (_: id: inventory.${id}) ingressIds;
  registry = net.fqdn lab.routes.registry-api.host;

  internal = routesOf "internal";
  external = routesOf "external";
  # where the prober and the dashboard's status dot check an http route: through its ingress, at its health path,
  # which the ingress answers past sso for them alone (modules/traefik); without one the route's own door
  probeUrlOf = r: "https://${net.fqdn r.host}${if r.health == null then r.path else r.health}";
  access = {
    admins = "admins";
    groups = lib.genAttrs ssoNames (name: "app-${name}");
  };
  l4 = lib.listToAttrs (map (e: lib.nameValuePair e.name e.route) l4Entries);
  forwarded = lib.listToAttrs (map (e: lib.nameValuePair e.name e.route) (lib.filter (e: e.route.publicPort != null) l4Entries));

  problems = duplicatesBy (e: e.name) "route name" routeEntries
    ++ map (e: "${e.owner} route ${e.name}: an srv record points at the house's publicPort, which the route lacks")
      (lib.filter (e: e.route.srv != null && e.route.publicPort == null) l4Entries)
    ++ map (e: "${e.owner} route ${e.name}: an http route goes through its zone's ingress, publicPort is for tcp and udp")
      (lib.filter (e: e.route.protocol == "http" && e.route.publicPort != null) routeEntries)
    # an idle deployment sleeps until an ingress's wake proxy sees a connection; the router forwards past it
    ++ map (e: "${e.owner} route ${e.name}: a ${e.route.protocol} route goes from the router straight to its backend, which no wake proxy sees; its deployment cannot idle")
      (lib.filter (e: if e.route.app != null then apps.${e.route.app}.idle.stopAfter != null
        else inventory.${toString e.route.vmid}.idle != null) l4Entries)
    # the house's public address: https for the ingresses, wireguard for the owner's devices, every l4 route once
    ++ duplicatesBy (e: "${e.route.protocol}/${toString e.route.publicPort}") "public port"
      (lib.filter (e: e.route.publicPort != null) l4Entries ++ [
        { name = "https"; owner = "the edge"; route = { protocol = "tcp"; publicPort = net.ports.https; }; }
        { name = "wireguard"; owner = "the router"; route = { protocol = "udp"; publicPort = net.ports.wireguard; }; }
      ])
    ++ map (app: "apps.${app}: the name is an instance service's too; a service key names one deployment")
      (lib.intersectLists (lib.attrNames appsCatalog.apps) (lib.attrNames lab.routes))
    ++ hostProblems
    ++ zoneProblems
    ++ portProblems
    ++ lib.concatLists (lib.mapAttrsToList appProblems allApps)
    ++ lib.concatLists (lib.mapAttrsToList (name: c: map (p: "swarm ${name}: ${p}") (admissionOf c).problems) clusters)
    ++ lib.optional (appsCatalog.swarm.portRange.first > appsCatalog.swarm.portRange.last) "swarm.portRange: first is above last";
}
