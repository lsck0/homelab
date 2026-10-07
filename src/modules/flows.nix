# who may open a connection to whom: the lab's network policy as data, read in one place
#
# Five lists, each entry with the reason it exists:
# - networks: the router's interfaces and where each may connect by default. A trusted network reaches
#   everything, the house lan the lab's zones, an isolated zone (a dmz) the internet only.
# - guards: grants of one or more guests onto ports of one guest. A grant is the whole path: the guest's guard admits
#   the sources (modules/network.nix, ports guarded with homelab.ingressOnly; its zone's ingress and loopback are
#   trusted there already), and every source whose network the router would not let through gets its forward.
# - forward: the network-wide exceptions across the router: one source, one destination, its ports.
# - router: the router's own services and who may use them.
# - portForwards: the house's public address forwarded: https to the edge, every tcp and udp route to its backend.
#
# instances/300-router/main.nix renders networks, forward, router and portForwards; modules/network.nix renders the
# grants onto the guest it runs on. A grant onto one instance lives in its instance.nix (`grants`, collected by
# modules/lab), a route's own path from its ingress is derived from the route; what spans the lab stays here.
# tests/lib/zones.py states the router's part independently and tests/router-zones.nix holds the running router to it.
#
# An endpoint is { network; addresses; }: a network of `networks`, and the addresses in it (null: all of it).
{ lib, net, inventory, catalog, nasClients, lab }:
let
  inherit (net) ports zones;
  telemetry = import ./telemetry.nix { inherit lib inventory; };

  # -------------------------------------------------------------------------------------------------------------
  # ENDPOINTS
  # -------------------------------------------------------------------------------------------------------------

  # guests by vmid; all in one zone, so one rule names them
  hosts = ids:
    let networks = lib.unique (map (id: (net.zoneOf id).name) ids); in
    assert lib.assertMsg (lib.length networks == 1) "flows.nix: ${toString ids} span zones ${toString networks}";
    { network = lib.head networks; addresses = map net.ipOf ids; };
  host = id: hosts [ id ];
  # every address of a network
  all = name: { network = name; addresses = null; };
  # a zone's dhcp clients: a discover comes from 0.0.0.0, a renewal from the leased address
  dhcpClients = name: { network = name; addresses = [ "0.0.0.0" zones.${name}.subnet ]; };
  house = addresses: { network = "lan"; inherit addresses; };
  # any source the wan carries: the house and, through the fritzbox's forwards, the internet
  anywhere = { network = "lan"; addresses = [ "0.0.0.0/0" ]; };
  # the guests of a zone vm-109 exports to (lab.nasClients), none when it exports to none there
  nasClientsIn = name: {
    network = name;
    addresses = lib.filter (ip: lib.elem ip zones.${name}.hosts) (lib.attrNames nasClients);
  };

  # -------------------------------------------------------------------------------------------------------------
  # ROLES
  # -------------------------------------------------------------------------------------------------------------

  internalIngress = zones.internal.ingress;
  edge = zones.external.ingress;
  collector = telemetry.collectorVmid;
  inherit (lab.roles) nas dashboard;
  prowlarr = toString lab.routes.prowlarr.vmid;
  swarmManager = catalog.swarm.managerId;

  nfsPorts = [ ports.rpcbind ports.nfs ];
  torPorts = import ./tor-ports.nix;
  # the push doors only: no sender outside the internal zone reaches a query api
  appTelemetryPorts = with telemetry.ports; [ journalRemote otlpGrpc otlpHttp pyroscope lokiPush ];

  # -------------------------------------------------------------------------------------------------------------
  # ROUTE BACKENDS
  # -------------------------------------------------------------------------------------------------------------

  running = id: inventory.${id}.powered;
  # the swarm an app runs on: the shared one or its own guest (catalog.clusters)
  clusterOf = app: lib.findFirst (c: c.apps ? ${app}) (throw "flows.nix: app ${app} is in no cluster") (lib.attrValues catalog.clusters);
  # the running guests a route's backend answers on: an instance's own, or every node of its app's cluster
  backendIdsOf = r: lib.filter running (if r.vmid != null then [ (toString r.vmid) ] else (clusterOf r.app).workerIds);

  httpRoutes = lib.attrValues (catalog.internal // catalog.external);
  # every guest app tasks run on: the shared swarm's workers and each guest-placed app's own guest
  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  # the app guests outside the apps zone, by zone: their telemetry crosses the router like the workers'
  appGuestsByZone = lib.groupBy (id: (net.zoneOf id).name) (lib.filter (id: (net.zoneOf id).name != "apps") appNodeIds);

  # -------------------------------------------------------------------------------------------------------------
  # GRANTS
  # -------------------------------------------------------------------------------------------------------------

  # every route from the ingress of its zone to each guest answering it; a guest's own zone ingress is trusted already
  routeGrants = lib.concatMap (r: let ingress = zones.${r.zone}.ingress; in map (id: {
    from = [ ingress ]; to = id; tcp = [ r.port ];
    why = "the ${r.zone} ingress serves ${net.fqdn r.host}";
  }) (lib.filter (id: (net.zoneOf id).ingress != ingress) (backendIdsOf r))) httpRoutes;

  # a dashboard widget with no url of its own queries its route's api on the guest
  widgetGrants = map (c: let r = lab.routes.${c.route}; in {
    from = [ dashboard ]; to = toString r.vmid; tcp = [ r.port ];
    why = "the dashboard's ${c.widget.type} widget queries ${c.route}";
  }) (lib.filter (c: c.widget != null && c.widget.url == null) lab.homepage);

  # who wakes an idle app on the deploy controller: the ingresses for a request, the state worker for a dump;
  # modules/swarm admits the same list in the controller itself
  controllerWakerIds = lib.unique [ internalIngress edge catalog.swarm.stateId ];
  wakerGrants = [{
    from = controllerWakerIds; to = swarmManager; tcp = [ catalog.swarm.controllerPort ];
    why = "the ingresses wake an idle app for a request, the state worker for its nightly dump";
  }];

  ingressMetricsGrants = map (z: {
    from = [ collector ]; to = z.ingress; tcp = [ ports.traefikMetrics ];
    why = "vm-105 scrapes the ${z.name} ingress";
  }) (lib.filter (z: z.ingress != null) (lib.attrValues zones));

  metricsGrants = map (id: {
    from = [ collector ]; to = id; tcp = catalog.ports.metrics ++ [ catalog.swarm.cadvisorPort telemetry.ports.promtail ];
    why = "vm-105 scrapes the apps' metrics, and each app node's cadvisor and log shipper";
  }) appNodeIds
  ++ lib.mapAttrsToList (key: s: {
    from = [ collector ]; to = toString s.vmid; tcp = lib.unique (map (m: m.port) (lib.attrValues s.metrics));
    why = "vm-105 scrapes ${key}'s exporters";
  }) (lib.filterAttrs (_: s: s.vmid != null && s.on.metrics && s.metrics != { }) catalog.services);

  # the prober's checks of a lab-only tcp route at its guest
  probeGrants = map (r: {
    from = [ collector ]; to = toString r.vmid; tcp = [ r.port ];
    why = "vm-105 probes the lab-only tcp route ${r.host}";
  }) (lib.filter (r: r.vmid != null && r.protocol == "tcp" && r.publicPort == null && r.off.probe == null) (lib.attrValues catalog.l4));

  guards = routeGrants ++ widgetGrants ++ wakerGrants ++ ingressMetricsGrants ++ metricsGrants ++ probeGrants
    # an instance's own `grants`: who may reach which of its guarded ports
    ++ lab.grants;

  # a grant's source as the router sees it (modules/lab `sourceOf` names them): the router itself crosses nothing
  endpointOf = from:
    if builtins.match "[0-9]+" from != null then host from
    else if lib.elem from [ "proxmox" "workstation" ] then house [ net.wan.${from} ]
    else all from;
  reachesByDefault = network: zone: let r = networks.${network}.reaches; in r == "everything" || (lib.isList r && lib.elem zone r);
  # the router's part of a grant: each source network that does not reach the guest's zone by default
  grantForwards = g: let target = (net.zoneOf g.to).name; in lib.concatLists (lib.mapAttrsToList (network: es:
    lib.optional (network != target && !(reachesByDefault network target)) {
      from = { inherit network; addresses = if lib.any (e: e.addresses == null) es then null else lib.concatMap (e: e.addresses) es; };
      to = host g.to; inherit (g) tcp why;
    }) (lib.groupBy (e: e.network) (map endpointOf (lib.remove "router" g.from))));
  # one rule for the guests of one zone that the same sources reach on the same ports for the same reason
  forwardsMerged = fs: lib.mapAttrsToList (_: group: lib.head group // {
    to = (lib.head group).to // { addresses = lib.unique (lib.concatMap (f: f.to.addresses) group); };
  }) (lib.groupBy (f: builtins.toJSON { inherit (f) from tcp why; network = f.to.network; }) fs);

  # -------------------------------------------------------------------------------------------------------------
  # NETWORKS: the router's interfaces, by default reach
  # -------------------------------------------------------------------------------------------------------------

  networks = {
    internal = { interface = zones.internal.interface; sources = [ zones.internal.subnet ]; reaches = "everything"; };
    # the owner's devices (instances/300-router/main.nix wg0 peers)
    wireguard = { interface = "wg0"; sources = [ net.wireguard.subnet ]; reaches = "everything"; };
    # the house routes the lab through the router; the apps zone it reaches only through the ingresses
    lan = { interface = net.wan.interface; sources = [ net.wan.subnet ]; reaches = [ "internal" "external" ]; };
    external = { interface = zones.external.interface; sources = [ zones.external.subnet ]; reaches = "internet"; };
    apps = { interface = zones.apps.interface; sources = [ zones.apps.subnet ]; reaches = "internet"; };
  };
in
{
  inherit networks guards controllerWakerIds;

  # -------------------------------------------------------------------------------------------------------------
  # FORWARD: the exceptions across the router; a dmz reaches nothing private but these
  # -------------------------------------------------------------------------------------------------------------

  forward = forwardsMerged (lib.concatMap grantForwards guards) ++ [
    {
      from = house [ net.wan.workstation ]; to = all "apps"; tcp = [ ports.ssh ];
      why = "sync.sh on the workstation deploys the swarm workers over ssh like every guest";
    }
    {
      from = host edge; to = host internalIngress; tcp = [ ports.https ];
      why = "the edge relays the internal routes it publishes to the internal ingress";
    }
    {
      from = host edge; to = host collector; tcp = [ telemetry.ports.lokiPush ];
      why = "the edge's promtail pushes its access log";
    }
    {
      from = all "external"; to = host collector; tcp = [ telemetry.ports.journalRemote ];
      why = "every dmz guest uploads its journal";
    }
    {
      from = nasClientsIn "external"; to = host nas; tcp = nfsPorts; udp = nfsPorts;
      why = "dmz guests mount the nas shares vm-109 exports to them";
    }
    {
      from = host edge; to = house [ net.wan.proxmox ]; tcp = [ ports.proxmoxApi ];
      why = "the edge wakes the dmz's onDemand guests; its token powers only their pool";
    }
    {
      from = all "apps"; to = host internalIngress; tcp = [ ports.https ];
      why = "the workers pull their images from the registry route";
    }
    {
      from = all "apps"; to = host collector; tcp = appTelemetryPorts;
      why = "the workers upload journals and ship their apps' logs, the apps send traces and profiles";
    }
    {
      from = host collector; to = { network = "apps"; addresses = zones.apps.hosts; }; tcp = [ telemetry.ports.promtail ];
      why = "vm-105 scrapes the workers' log shippers for dropped lines";
    }
    {
      from = host edge; to = host collector; tcp = [ telemetry.ports.otlpFrontend ];
      why = "the edge relays the browsers' frontend telemetry";
    }
    {
      from = all "apps"; to = host swarmManager;
      tcp = [ ports.swarmManager ports.swarmGossip ]; udp = [ ports.swarmGossip ports.vxlan ]; esp = true;
      why = "the workers reach their manager (internal zone, by decision): control, gossip, the overlay and its ipsec";
    }
    {
      from = nasClientsIn "apps"; to = host nas; tcp = nfsPorts; udp = nfsPorts;
      why = "the workers vm-109 exports to mount their shares";
    }
  ]
  ++ lib.mapAttrsToList (zone: ids: {
    from = hosts ids; to = host collector; tcp = appTelemetryPorts;
    why = "the guest-placed apps' own guests in ${zone} ship their logs, traces and profiles like the workers";
  }) appGuestsByZone;

  # -------------------------------------------------------------------------------------------------------------
  # ROUTER: its own services, never the dmz's ssh or metrics
  # -------------------------------------------------------------------------------------------------------------

  router = [
    {
      from = all "lan"; tcp = [ ports.ssh ports.dns ]; udp = [ ports.dns ports.mdns ];
      why = "the house administers it and resolves through it";
    }
    {
      from = anywhere; udp = [ ports.wireguard ];
      why = "the owner's devices dial in from anywhere";
    }
    {
      from = all "internal"; tcp = [ ports.ssh ports.dns ]; udp = [ ports.dns ];
      why = "dns for the zone, ssh for its operators (hermes, deploys)";
    }
    {
      from = dhcpClients "internal"; udp = [ ports.dhcpServer ];
      why = "dhcp for installs and unconfigured guests in the zone";
    }
    {
      from = host collector; tcp = [ ports.nodeExporter ];
      why = "vm-105 scrapes the router's node exporter";
    }
    {
      from = host prowlarr; tcp = [ torPorts.socksIsolated ];
      why = "prowlarr's indexer searches leave through tor";
    }
    {
      from = all "wireguard"; tcp = [ ports.ssh ports.dns ]; udp = [ ports.dns ];
      why = "the owner's devices administer the lab from outside";
    }
    {
      from = all "external"; tcp = [ ports.dns ]; udp = [ ports.dns ];
      why = "dns for the dmz";
    }
    {
      from = dhcpClients "external"; udp = [ ports.dhcpServer ];
      why = "dhcp for installs and unconfigured guests in the dmz";
    }
    {
      from = all "apps"; tcp = [ ports.dns ]; udp = [ ports.dns ];
      why = "dns for the workers; their addresses are static, no dhcp";
    }
  ];

  # -------------------------------------------------------------------------------------------------------------
  # PORT FORWARDS: the house's public address, forwarded
  # -------------------------------------------------------------------------------------------------------------

  portForwards = [
    {
      proto = "tcp"; port = ports.https; addresses = [ (net.ipOf edge) ]; targetPort = ports.https;
      host = null; srv = null; why = "every public route";
      off = { inflightLimit = "the edge limits every client itself"; accessLog = "traefik logs every request"; };
    }
  ]
  # every tcp and udp route (an instance service's or an app's) to every guest answering it, while one runs
  ++ lib.filter (f: f.addresses != [ ]) (map (r: {
    proto = r.protocol; port = r.publicPort; targetPort = r.port;
    addresses = map net.ipOf (backendIdsOf r);
    inherit (r) host srv off;
    why = "${r.protocol} ${net.fqdn r.host}";
  }) (lib.attrValues catalog.l4));
}
