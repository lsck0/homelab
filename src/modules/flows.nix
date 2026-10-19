# who may open a connection to whom: the lab's network policy as data, each entry with the reason it exists
#
# networks: the router's interfaces and their default reach. guards: grants of guests onto ports of one guest, the whole
# path (its guard admits the sources, and the router forwards for any source it would not let through). forward: the
# network-wide exceptions across the router. router: its own services. portForwards: the house's public address.
# recovery: who reaches every guest's ssh and node exporter, which no ingress or neighbour does.
#
# the router (instances/core/300-router) renders all but the grants and recovery, which modules/network.nix renders on
# their guest; a grant onto one instance lives in its instance.nix `grants`. tests/lib/zones.py states the router's part
# independently. An endpoint is { network; addresses; }, addresses null for all of the network.
# security: no zone reaches the house or another zone by default, the internal one included; what it needs there is a
# forward naming its guests.
{
  lib,
  net,
  inventory,
  catalog,
  nasClients,
  lab,
}:
let
  inherit (net) ports zones;
  telemetry = import ./telemetry.nix { inherit lib inventory; };

  # guests by vmid; all in one zone, so one rule names them
  hosts =
    ids:
    let
      networks = lib.unique (map (id: (net.zoneOf id).name) ids);
    in
    assert lib.assertMsg (lib.length networks == 1) "flows.nix: ${toString ids} span zones ${toString networks}";
    {
      network = lib.head networks;
      addresses = map net.ipOf ids;
    };
  host = id: hosts [ id ];
  all = name: {
    network = name;
    addresses = null;
  };
  # a discover comes from 0.0.0.0, a renewal from the leased address
  dhcpClients = name: {
    network = name;
    addresses = [
      "0.0.0.0"
      zones.${name}.subnet
    ];
  };
  house = addresses: {
    network = "lan";
    inherit addresses;
  };
  # any source the wan carries: the house and, through the fritzbox's forwards, the internet
  anywhere = {
    network = "lan";
    addresses = [ "0.0.0.0/0" ];
  };
  nasClientsIn = name: {
    network = name;
    addresses = lib.filter (ip: lib.elem ip zones.${name}.hosts) (lib.attrNames nasClients);
  };

  internalIngress = zones.internal.ingress;
  edge = zones.external.ingress;
  collector = telemetry.collectorVmid;
  inherit (lab.roles) nas dashboard operator;
  prowlarr = toString lab.routes.prowlarr.vmid;
  swarmManager = catalog.swarm.managerId;
  inherit (catalog.swarm) builderId;

  nfsPorts = [
    ports.rpcbind
    ports.nfs
  ];
  torPorts = import ./tor-ports.nix;
  torMembersByZone = lib.groupBy (id: (net.zoneOf id).name) (
    lib.attrNames (lib.filterAttrs (_: e: e.via == "tor") lab.egress)
  );
  # the push doors only: no sender outside the internal zone reaches a query api
  appTelemetryPorts = with telemetry.ports; [
    journalRemote
    otlpGrpc
    otlpHttp
    pyroscope
    lokiPush
  ];

  running = id: inventory.${id}.powered;
  clusterOf =
    app:
    lib.findFirst (c: c.apps ? ${app}) (throw "flows.nix: app ${app} is in no cluster") (lib.attrValues catalog.clusters);
  # the running guests a route's backend answers on: an instance's own, or every node of its app's cluster
  backendIdsOf = r: lib.filter running (if r.vmid != null then [ (toString r.vmid) ] else (clusterOf r.app).workerIds);

  httpRoutes = lib.attrValues (catalog.internal // catalog.external);
  appNodeIds = lib.unique (lib.concatMap (c: c.workerIds) (lib.attrValues catalog.clusters));
  # the app guests outside the apps zone, by zone: their telemetry crosses the router like the workers'
  appGuestsByZone = lib.groupBy (id: (net.zoneOf id).name) (lib.filter (id: (net.zoneOf id).name != "apps") appNodeIds);
  forwardedRoutes = lib.attrValues catalog.forwarded;

  # every route from the ingress of its zone to each guest answering it; a guest's own zone ingress is trusted already
  routeGrants = lib.concatMap (
    r:
    let
      inherit (zones.${r.zone}) ingress;
    in
    map (id: {
      from = [ ingress ];
      to = id;
      tcp = [ r.port ];
      why = "the ${r.zone} ingress serves ${net.fqdn r.host}";
    }) (lib.filter (id: (net.zoneOf id).ingress != ingress) (backendIdsOf r))
  ) httpRoutes;

  # a dashboard widget with no url of its own queries its route's api on the guest
  widgetGrants = map (
    c:
    let
      r = lab.routes.${c.route};
    in
    {
      from = [ dashboard ];
      to = toString r.vmid;
      tcp = [ r.port ];
      why = "the dashboard's ${c.widget.type} widget queries ${c.route}";
    }
  ) (lib.filter (c: c.widget != null && c.widget.url == null) lab.homepage);

  # catalog.clusters `wakers`, which modules/swarm admits too
  wakerGrants = lib.mapAttrsToList (name: c: {
    from = lib.remove c.managerId c.wakers;
    to = c.managerId;
    tcp = [ catalog.swarm.controllerPort ];
    why = "the ingresses wake swarm ${name}'s idle apps for a request, its state worker for a nightly dump";
  }) catalog.clusters;

  builderGrants = lib.mapAttrsToList (name: c: {
    from = [ builderId ];
    to = c.managerId;
    tcp = [ ports.ssh ];
    why = "the builder deploys swarm ${name}'s guest-placed apps over ssh, its key restricted to that";
  }) (removeAttrs catalog.clusters [ "shared" ]);

  ingresses = lib.filter (z: z.ingress != null) (lib.attrValues zones);
  ingressGrants = map (z: {
    from = [ collector ];
    to = z.ingress;
    tcp = [
      ports.traefikMetrics
      telemetry.ports.promtail
      telemetry.ports.crowdsecMetrics
      telemetry.ports.anubisMetrics
    ];
    why = "vm-103 scrapes the ${z.name} ingress, its crowdsec and anubis, and its access log shipper's dropped lines";
  }) ingresses;

  metricsGrants =
    map (id: {
      from = [ collector ];
      to = id;
      tcp = catalog.ports.metrics ++ [
        catalog.swarm.cadvisorPort
        telemetry.ports.promtail
      ];
      why = "vm-103 scrapes the apps' metrics, and each app node's cadvisor and log shipper";
    }) appNodeIds
    ++ lib.mapAttrsToList (key: s: {
      from = [ collector ];
      to = toString s.vmid;
      tcp = lib.unique (map (m: m.port) (lib.attrValues s.metrics));
      why = "vm-103 scrapes ${key}'s exporters";
    }) (lib.filterAttrs (_: s: s.vmid != null && s.on.metrics && s.metrics != { }) catalog.services);

  probeGrants =
    map
      (r: {
        from = [ collector ];
        to = toString r.vmid;
        tcp = [ r.port ];
        why = "vm-103 probes the lab-only tcp route ${r.host}";
      })
      (
        lib.filter (r: r.vmid != null && r.protocol == "tcp" && r.publicPort == null && lib.elem "probe" r.on) (
          lib.attrValues catalog.l4
        )
      );

  # instances/core/300-router/lib/onion-services.nix
  onionGrants = lib.optional (lib.any (r: r.onionAddress != null) (lib.attrValues catalog.external)) {
    from = [ "router" ];
    to = edge;
    tcp = [ torPorts.onionIngress ];
    why = "the router's tor hands the onion routes' visitors to the edge";
  };

  guards =
    routeGrants
    ++ widgetGrants
    ++ wakerGrants
    ++ builderGrants
    ++ ingressGrants
    ++ metricsGrants
    ++ probeGrants
    ++ onionGrants
    ++ lab.grants;

  # a grant's source as the router sees it (modules/lab `sourceOf` names them): the router itself crosses nothing
  endpointOf =
    from:
    if builtins.match "[0-9]+" from != null then
      host from
    else if
      lib.elem from [
        "proxmox"
        "workstation"
        "notebook"
      ]
    then
      house [ net.wan.${from} ]
    else
      all from;
  reachesByDefault =
    network: zone:
    let
      r = networks.${network}.reaches;
    in
    r == "everything" || (lib.isList r && lib.elem zone r);
  # the router's part of a grant: each source network that does not reach the guest's zone by default
  grantForwards =
    g:
    let
      target = (net.zoneOf g.to).name;
    in
    lib.concatLists (
      lib.mapAttrsToList (
        network: es:
        lib.optional (network != target && !(reachesByDefault network target)) {
          from = {
            inherit network;
            addresses = if lib.any (e: e.addresses == null) es then null else lib.concatMap (e: e.addresses) es;
          };
          to = host g.to;
          inherit (g) tcp why;
        }
      ) (lib.groupBy (e: e.network) (map endpointOf (lib.remove "router" g.from)))
    );
  # one rule for the guests of one zone that the same sources reach on the same ports for the same reason
  forwardsMerged =
    fs:
    lib.mapAttrsToList
      (
        _: group:
        lib.head group
        // {
          to = (lib.head group).to // {
            addresses = lib.unique (lib.concatMap (f: f.to.addresses) group);
          };
        }
      )
      (
        lib.groupBy (
          f:
          builtins.toJSON {
            inherit (f) from tcp why;
            inherit (f.to) network;
          }
        ) fs
      );

  networks = {
    internal = {
      inherit (zones.internal) interface;
      sources = [ zones.internal.subnet ];
      reaches = "internet";
    };
    # the owner's devices (instances/core/300-router/main.nix wg0 peers)
    wireguard = {
      interface = "wg0";
      sources = [ net.wireguard.subnet ];
      reaches = "everything";
    };
    # the house routes the lab through the router; the apps zone it reaches only through the ingresses
    lan = {
      inherit (net.wan) interface;
      sources = [ net.wan.subnet ];
      reaches = [
        "internal"
        "external"
      ];
    };
    external = {
      inherit (zones.external) interface;
      sources = [ zones.external.subnet ];
      reaches = "internet";
    };
    apps = {
      inherit (zones.apps) interface;
      sources = [ zones.apps.subnet ];
      reaches = "internet";
    };
  };

  # what the internal zone reaches beyond the internet: the house's machines it administers or reads, the edge as any
  # visitor does, and the guests of the other zones it administers
  internalForwards = [
    {
      from = host operator;
      to = house [ net.wan.proxmox ];
      tcp = [ ports.ssh ];
      why = "hermes administers proxmox, its api through pvesh";
    }
    {
      from = hosts [
        internalIngress
        dashboard
      ];
      to = house [ net.wan.proxmox ];
      tcp = [ ports.proxmoxApi ];
      why = "the internal ingress serves proxmox's page and wakes the zone's idle guests, the dashboard reads its widget";
    }
    {
      from = host collector;
      to = house [ net.wan.proxmox ];
      tcp = [ ports.nodeExporter ];
      why = "vm-103 scrapes proxmox's node exporter";
    }
    {
      from = host dashboard;
      to = house [ net.wan.gateway ];
      tcp = [
        ports.http
        ports.fritzboxUpnp
      ];
      why = "the dashboard's fritzbox card and widget";
    }
    {
      from = host dashboard;
      to = house [
        net.wan.gateway
        net.wan.proxmox
      ];
      icmp = true;
      why = "the dashboard's frame cards ping the fritzbox and proxmox";
    }
    {
      from = host dashboard;
      to = host edge;
      icmp = true;
      why = "the dashboard's frame card pings the edge";
    }
    {
      from = all "internal";
      to = host edge;
      tcp = [ ports.https ];
      why = "the lab calls the public routes as any visitor does: the prober, the dashboard's dots, alerts to ntfy";
    }
  ]
  ++ lib.optional (net.wan.inverter != null) {
    from = host collector;
    to = house [ net.wan.inverter ];
    tcp = [ ports.http ];
    why = "vm-103's fronius exporter reads the inverter's solar api";
  }
  ++
    lib.concatMap
      (zone: [
        {
          from = host operator;
          to = all zone;
          tcp = [ ports.ssh ];
          why = "hermes administers the ${zone} zone's guests";
        }
        {
          from = host collector;
          to = all zone;
          tcp = [ ports.nodeExporter ];
          why = "vm-103 scrapes the ${zone} zone's node exporters";
        }
      ])
      [
        "external"
        "apps"
      ]
  ++ [
    {
      from = host swarmManager;
      to = all "apps";
      tcp = [ ports.swarmGossip ];
      udp = [
        ports.swarmGossip
        ports.vxlan
      ];
      esp = true;
      why = "the manager gossips with its workers and carries the overlay to them";
    }
  ]
  # a forwarded tcp route, unguarded on its guest, the world's to reach
  ++ lib.concatMap (
    r:
    let
      ids = backendIdsOf r;
    in
    lib.optional (ids != [ ] && (net.zoneOf (lib.head ids)).name != "internal") {
      from = host collector;
      to = hosts ids;
      tcp = [ r.port ];
      why = "vm-103 probes the forwarded route ${net.fqdn r.host} at its guest";
    }
  ) (lib.filter (r: r.protocol == "tcp" && lib.elem "probe" r.on) forwardedRoutes);
in
{
  inherit networks guards;

  # the exceptions across the router; no zone reaches anything private but these
  forward =
    forwardsMerged (lib.concatMap grantForwards guards)
    ++ internalForwards
    ++ [
      {
        from = house [ net.wan.workstation ];
        to = all "apps";
        tcp = [ ports.ssh ];
        why = "sync.nu on the workstation deploys the swarm workers over ssh like every guest";
      }
      {
        from = host edge;
        to = host internalIngress;
        tcp = [ ports.https ];
        why = "the edge relays the internal routes it publishes to the internal ingress";
      }
      {
        from = host edge;
        to = host collector;
        tcp = with telemetry.ports; [
          lokiPush
          otlpGrpc
        ];
        why = "the edge's promtail pushes its access log, its traefik its request spans";
      }
      {
        from = all "external";
        to = host collector;
        tcp = [ telemetry.ports.journalRemote ];
        why = "every dmz guest uploads its journal";
      }
      {
        from = nasClientsIn "external";
        to = host nas;
        tcp = nfsPorts;
        udp = nfsPorts;
        why = "dmz guests mount the nas shares vm-104 exports to them";
      }
      {
        from = host edge;
        to = house [ net.wan.proxmox ];
        tcp = [ ports.proxmoxApi ];
        why = "the edge wakes the dmz's onDemand guests; its token powers only their pool";
      }
      {
        from = all "apps";
        to = host internalIngress;
        tcp = [ ports.https ];
        why = "the workers pull their images from the registry route";
      }
      {
        from = all "apps";
        to = host collector;
        tcp = appTelemetryPorts;
        why = "the workers upload journals and ship their apps' logs, the apps send traces and profiles";
      }
      {
        from = all "apps";
        to = host swarmManager;
        tcp = [
          ports.swarmManager
          ports.swarmGossip
        ];
        udp = [
          ports.swarmGossip
          ports.vxlan
        ];
        esp = true;
        why = "the workers reach their manager (internal zone, by decision): control, gossip, the overlay and its ipsec";
      }
      {
        from = nasClientsIn "apps";
        to = host nas;
        tcp = nfsPorts;
        udp = nfsPorts;
        why = "the workers vm-104 exports to mount their shares";
      }
    ]
    ++ lib.mapAttrsToList (zone: ids: {
      from = hosts ids;
      to = host collector;
      tcp = appTelemetryPorts;
      why = "the guest-placed apps' own guests in ${zone} ship their logs, traces and profiles like the workers";
    }) appGuestsByZone;

  # never the dmz's ssh or metrics
  router = [
    {
      from = all "lan";
      tcp = [
        ports.ssh
        ports.dns
      ];
      udp = [
        ports.dns
        ports.mdns
      ];
      why = "the house administers it and resolves through it";
    }
    {
      from = anywhere;
      udp = [ ports.wireguard ];
      why = "the owner's devices dial in from anywhere";
    }
    {
      from = all "internal";
      tcp = [
        ports.ssh
        ports.dns
      ];
      udp = [ ports.dns ];
      why = "dns for the zone, ssh for its operators (hermes, deploys)";
    }
    {
      from = dhcpClients "internal";
      udp = [ ports.dhcpServer ];
      why = "dhcp for installs and unconfigured guests in the zone";
    }
    {
      from = host collector;
      tcp = [ ports.nodeExporter ];
      why = "vm-103 scrapes the router's node exporter";
    }
    {
      from = host prowlarr;
      tcp = [ torPorts.socksIsolated ];
      why = "prowlarr's indexer searches leave through tor";
    }
    {
      from = all "wireguard";
      tcp = [
        ports.ssh
        ports.dns
      ];
      udp = [ ports.dns ];
      why = "the owner's devices administer the lab from outside";
    }
    {
      from = all "external";
      tcp = [ ports.dns ];
      udp = [ ports.dns ];
      why = "dns for the dmz";
    }
    {
      from = dhcpClients "external";
      udp = [ ports.dhcpServer ];
      why = "dhcp for installs and unconfigured guests in the dmz";
    }
    {
      from = all "apps";
      tcp = [ ports.dns ];
      udp = [ ports.dns ];
      why = "dns for the workers; their addresses are static, no dhcp";
    }
  ]
  ++ lib.mapAttrsToList (zone: ids: {
    from = hosts ids;
    tcp = [ torPorts.trans ];
    why = "the tor egress members in ${zone}: their internet tcp, redirected into tor's transparent port";
  }) torMembersByZone;

  # the sources each guest's ssh and node exporter admit (modules/network.nix): the owner's machines, the router's leg
  # (sync.nu's bastion), hermes, the collector, and whoever a guard grants the guest's ssh
  recovery = id: {
    ssh = [
      "workstation"
      "notebook"
      "wireguard"
      "router"
      operator
    ]
    ++ lib.concatMap (g: g.from) (lib.filter (g: g.to == id && lib.elem ports.ssh g.tcp) guards);
    nodeExporter = [ collector ];
  };

  portForwards = [
    {
      proto = "tcp";
      port = ports.https;
      addresses = [ (net.ipOf edge) ];
      targetPort = ports.https;
      host = null;
      srv = null;
      why = "every public route";
      # the edge limits and logs every client itself
      on = [ ];
    }
  ]
  # every forwarded tcp and udp route (an instance service's or an app's) to every guest answering it, while one runs
  ++ lib.filter (f: f.addresses != [ ]) (
    map (r: {
      proto = r.protocol;
      port = r.publicPort;
      targetPort = r.port;
      addresses = map net.ipOf (backendIdsOf r);
      inherit (r) host srv on;
      why = "${r.protocol} ${net.fqdn r.host}";
    }) forwardedRoutes
  );
}
