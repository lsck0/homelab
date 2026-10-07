# who may open a connection to whom: the lab's network policy as data, read in one place
#
# Five lists, each entry with the reason it exists:
# - networks: the router's interfaces and where each may connect by default. A trusted network reaches
#   everything, the house lan the lab's zones, an isolated zone (a dmz) the internet only.
# - forward: the exceptions that cross the router: one source, one destination, its ports.
# - router: the router's own services and who may use them.
# - portForwards: the house's public address forwarded: https to the edge, every tcp and udp route to its backend.
# - guards: grants inside a zone, onto ports a guest guards with homelab.ingressOnly (the zone's ingress and loopback
#   are trusted there already, everyone else needs a line here).
#
# instances/300-router/main.nix renders networks, forward, router and portForwards; modules/network.nix renders the
# guards of the guest it runs on. A grant onto one instance lives in its instance.nix (`grants`, collected by
# modules/lab), a tcp or udp forward is a route of its service; what spans the lab stays here. Ports come from
# their owners: modules/net.nix (protocols), modules/telemetry.nix (vm-105), an instance's routes, the swarm apps
# (src/apps/). tests/lib/zones.py states the router's part independently and tests/router-zones.nix holds the running
# router to it.
#
# An endpoint is { network; addresses; }: a network of `networks`, and the addresses in it (null: all of it).
{ lib, net, inventory, catalog, appsCatalog, nasClients, lab }:
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
  # the guests of a zone vm-109 exports to (modules/nas-clients.nix), none when it exports to none there
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
  # the guests behind these services
  nas = toString lab.routes.nas.vmid;
  homepage = toString lab.routes.homepage.vmid;
  prowlarr = toString lab.routes.prowlarr.vmid;
  swarmManager = toString appsCatalog.swarm.manager;


  nfsPorts = [ ports.rpcbind ports.nfs ];
  torPorts = import ./tor-ports.nix;

  # a public route of a guest outside the dmz: the edge reaches that one port of it, across the router and its guard
  innerPublicRoutes = lib.filter (r: r.vmid != null && (net.zoneOf (toString r.vmid)).name != "external") (lib.attrValues catalog.external);

  # every instance service's route as the guest and port it answers on
  vmRoutes = lib.attrValues (lib.filterAttrs (_: r: r.vmid != null) (catalog.internal // catalog.external));
  # every node of the apps zone: the routing mesh answers each app's published ports on all of them
  appNodes = { network = "apps"; addresses = zones.apps.hosts; };
  # every guest app tasks run on: the shared swarm's workers and each guest-placed app's own guest
  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  # the app guests outside the apps zone, by zone: their telemetry crosses the router like the workers'
  appGuestsByZone = lib.groupBy (id: (net.zoneOf id).name) (lib.filter (id: (net.zoneOf id).name != "apps") appNodeIds);
  appTelemetryPorts = with telemetry.ports; [ journalRemote otlpGrpc otlpHttp pyroscope loki ];
in
{
  # -------------------------------------------------------------------------------------------------------------
  # NETWORKS: the router's interfaces, by default reach
  # -------------------------------------------------------------------------------------------------------------

  networks = {
    internal = { interface = zones.internal.interface; sources = [ zones.internal.subnet ]; reaches = "everything"; };
    # the owner's devices (300-router.nix wg0 peers)
    wireguard = { interface = "wg0"; sources = [ net.wireguard.subnet ]; reaches = "everything"; };
    # the house routes the lab through the router; the swarm workers it reaches only through the ingresses
    lan = { interface = net.wan.interface; sources = [ net.wan.subnet ]; reaches = [ "internal" "external" ]; };
    external = { interface = zones.external.interface; sources = [ zones.external.subnet ]; reaches = "internet"; };
    apps = { interface = zones.apps.interface; sources = [ zones.apps.subnet ]; reaches = "internet"; };
  };

  # -------------------------------------------------------------------------------------------------------------
  # FORWARD: the exceptions across the router; a dmz reaches nothing private but these
  # -------------------------------------------------------------------------------------------------------------

  forward = map (r: {
    from = host edge; to = host (toString r.vmid); tcp = [ r.port ];
    why = "the edge serves the public route ${r.host} of a guest outside the dmz";
  }) innerPublicRoutes
  ++ [
    {
      from = house [ net.wan.workstation ]; to = all "apps"; tcp = [ ports.ssh ];
      why = "sync.sh on the workstation deploys the swarm workers over ssh like every guest";
    }
    {
      from = host edge; to = host internalIngress; tcp = [ ports.https ];
      why = "the edge relays the internal routes it publishes to the internal ingress";
    }
    {
      from = host edge; to = host collector; tcp = [ telemetry.ports.loki ];
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
      from = host edge; to = appNodes; tcp = catalog.ports.external;
      why = "the edge routes the apps' public paths to the ports the routing mesh publishes on every worker";
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
      from = host collector; to = appNodes; tcp = [ telemetry.ports.promtail ];
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
      proto = "tcp"; port = ports.https; address = net.ipOf edge; targetPort = ports.https;
      host = null; srv = null; why = "every public route";
      off = { inflightLimit = "the edge limits every client itself"; accessLog = "traefik logs every request"; };
    }
  ]
  # every tcp and udp route (an instance service's or an app's) straight to its backend, while it is not off
  ++ map (r: {
    proto = r.protocol; port = r.publicPort; targetPort = r.port;
    address = if r.vmid != null then net.ipOf (toString r.vmid) else lib.head r.nodes;
    inherit (r) host srv off;
    why = "${r.protocol} ${net.fqdn r.host}";
  }) (lib.filter (r: r.vmid == null || inventory.${toString r.vmid}.enabled != "false") (lib.attrValues catalog.l4));

  # -------------------------------------------------------------------------------------------------------------
  # GUARDS: grants onto ingressOnly ports inside a zone
  # -------------------------------------------------------------------------------------------------------------

  guards = lib.concatLists [
    (lib.unique (map (r: {
      from = [ homepage collector ]; to = toString r.vmid; tcp = [ r.port ];
      why = "the dashboard's status dot and the prober's blackbox check of every route's own port";
    }) vmRoutes))
    (map (r: {
      from = [ edge ]; to = toString r.vmid; tcp = [ r.port ];
      why = "the edge serves the public route ${r.host}";
    }) innerPublicRoutes)
    # an instance's own `grants`: who may reach which of its guarded ports
    lab.grants
    (map (id: {
      from = [ collector ]; to = id; tcp = catalog.ports.metrics ++ [ appsCatalog.cadvisorPort telemetry.ports.promtail ];
      why = "vm-105 scrapes the apps' metrics, and each app node's cadvisor and log shipper";
    }) appNodeIds)
    (lib.mapAttrsToList (key: s: {
      from = [ collector ]; to = toString s.vmid; tcp = lib.unique (map (m: m.port) (lib.attrValues s.metrics));
      why = "vm-105 scrapes ${key}'s exporters";
    }) (lib.filterAttrs (_: s: s.kind == "vm" && s.on.metrics && s.metrics != { }) catalog.services))
  ];
}
