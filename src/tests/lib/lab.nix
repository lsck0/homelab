# the lab in a nixos test: nodes that run the production module stack at their inventory addresses
#
# every lab node imports what a lab host runs, sops-nix and the platform swapped for stand-ins (tests/stubs/); it keeps
# its real hostname (vm-<id>, `vm_131` in the script) and address, trusts the test ca and has labprobe.
#   nodes.vm-131 = lab.guest "131" { };  nodes.luca-router = lab.router;  testScript = lab.driverPython + "...";
# vlans: a routed test puts each zone on its own vlan and boots `router`: 1 the house lan and wan, each zone's its router
# leg plus one. A flat test (`flat = true`) puts every node on vlan 1 with a /8, so a `multi` node owning outside
# addresses must also own the gateways (10.100.0.1/8, ...).
# nas: a guest's mounts bind its own disk (lib/nas-local.nix); `nas = true` mounts them from a `nas` node exporting
# exactly what the test's guests mount.
# apps: a test's own app folders (modules/lab withApps): every fact follows, the workers its apps need included.
{ pkgs, lib, specialArgs, apps ? null }:
let
  facts = if apps == null then specialArgs else let collected = specialArgs.lab.withApps apps; in
    assert lib.assertMsg (collected.problems == [ ]) "the test's apps break the lab's rules:\n${lib.concatLines collected.problems}";
    specialArgs // { lab = collected; inherit (collected) inventory site nasClients; };
  inherit (facts) inventory;

  pki = import ./pki.nix { inherit pkgs; };
  labprobe = import ./labprobe.nix { inherit pkgs; };

  net = import ../../modules/net.nix { inherit lib; inherit (facts) inventory site; };

  # proxmox's net0 is the router's wan
  wanVlan = 1;
  vlans = { lan = wanVlan; } // lib.mapAttrs (_: z: z.routerNic + wanVlan) net.zones;
  nasId = "104";
  # the slowest test runs about 10 min (monitoring, 615 s); a hang ends at three times that, not at the driver's hour
  globalTimeoutS = 1800;

  # what every lab node shares, whatever it runs
  node = {
    environment.systemPackages = [ labprobe ];
    security.pki.certificateFiles = [ pki.ca ];
    # ipv4 only, like the lab: the driver would add 2001:db8:: and fec0:: addresses no v4 rule covers
    networking.enableIPv6 = false;
  };
  # the driver's vlan nic of a guest or multi node; the router's nics carry their production names instead
  testNic = {
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
  };

  cidrParse = cidr: let parts = lib.splitString "/" cidr; in
    assert lib.assertMsg (lib.length parts == 2) "lab.multi: ${cidr} is no address/prefix";
    { address = lib.head parts; prefixLength = lib.toInt (lib.last parts); };
in rec {
  inherit (facts) inventory site nasClients;
  inherit pki labprobe vlans;
  # the named feature lists a fixture app opts into (modules/profiles.nix), as an app.nix gets them
  profiles = import ../../modules/profiles.nix;
  testDefaults.globalTimeout = lib.mkDefault globalTimeoutS;
  secretValues = import ./secret-values.nix { inherit pkgs; };
  images = import ./images.nix { inherit pkgs; };
  inherit (facts.lab) appsCatalog catalog withApps;
  routes = lib.genAttrs [ "internal" "external" ] (zone: lib.filterAttrs (_: r: r.zone == zone) facts.lab.routes);
  inherit (facts.lab) egress;
  # runNixOSTest's node.specialArgs: the hosts' facts. nasClients stays out: the router takes the lab's real one
  # (below), a test nas computes its own from the test's nodes, and a special arg could not be overridden
  specialArgs = { inherit (facts) inputs inventory site lab; };

  # the flake's `common` minus sops-nix, plus the platform options a test vm cannot get from platform-*.nix
  production = [
    ../../modules/base
    ../../modules/egress-vpn.nix
    ../stubs/sops.nix
    ../stubs/platform.nix
  ];

  # the inventory guest <vmid> through the real network.nix, at its address on the test nic eth1
  guest = vmid: { flat ? false, vlan ? (if flat then vlans.lan else vlans.${inventory.${vmid}.type}),
                  instance ? null, nas ? false }:
    let vm = inventory.${vmid}; in { config, ... }: {
      imports = production ++ [ node testNic (if nas then ./nas-mounts.nix else ./nas-local.nix) ]
        ++ lib.optional (instance != null) instance;
      # a secret its service parses holds a real-format value (secret-values.nix); a test may set its own
      testing.secretValues = lib.mapAttrs (_: lib.mkDefault) (lib.intersectAttrs config.sops.secrets (removeAttrs secretValues [ "public" ]));
      # its hostname, address and own services, as on the lab host (modules/network.nix)
      _module.args.instance = facts.lab.instances.${vmid};
      virtualisation.vlans = [ vlan ];
      # network.nix addresses eth0, the driver's own nic
      networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ {
        address = vm.ip;
        prefixLength = if flat then 8 else vm.prefix;
      } ];
      networking.defaultGateway = lib.mkForce { address = vm.gateway; interface = "eth1"; };
    };

  # one vm owning many addresses on one vlan: a zone's probe sources and listeners, or the world (gateways, the
  # internet, cloudflare, github, the house lan). No firewall: it stands in for networks, not for a lab host.
  # routes: networking.interfaces.<nic>.ipv4.routes entries, { address; prefixLength; via; }
  multi = { addresses, vlan ? vlans.lan, gateway ? null, routes ? [ ] }: {
    imports = [ node testNic ];
    virtualisation.vlans = [ vlan ];
    networking.useDHCP = false;
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce (map cidrParse addresses);
    networking.interfaces.eth1.ipv4.routes = routes;
    networking.defaultGateway = lib.mkIf (gateway != null) { address = gateway; interface = "eth1"; };
  };

  # the real router at its real nic names, with the lab's real nas clients (they shape its nfs rules)
  router = {
    imports = production ++ [ node ../../instances/core/300-router/main.nix ./offline-router.nix ];
    _module.args.nasClients = facts.nasClients;
    virtualisation.vlans = lib.mkForce [ ];
    virtualisation.interfaces = { ${net.wan.interface}.vlan = vlans.lan; }
      // lib.mapAttrs' (name: z: lib.nameValuePair z.interface { vlan = vlans.${name}; }) net.zones;
  };

  # the nas at 10.100.0.104, exporting exactly what the test's guests mount, by the real export rules
  nas = { flat ? false, vlan ? (if flat then vlans.lan else vlans.internal) }: { nodes, ... }: {
    imports = [ (guest nasId { inherit flat vlan; }) ../../instances/core/104-internal-nas/lib/nas-exports.nix ];
    homelab.nasExports.enable = true;
    _module.args.nasClients = import ./nas-clients.nix {
      inherit lib inventory;
      configs = lib.filterAttrs (_: config: config.networking.hostName != "vm-${nasId}") nodes;
    };
    # a fresh nfsd holds every open for its 90s grace period; the real nas left it long before its guests boot
    services.nfs.settings.nfsd = { grace-time = 10; lease-time = 10; };
  };

  # python for the test driver, prepended to a testScript: probe_sinks_start and probe_check (lib/probe.py),
  # http_request (lib/http.py)
  driverPython = ''
    LABPROBE = "${labprobe}/bin/labprobe"
  '' + builtins.readFile ./probe.py + builtins.readFile ./http.py;
}
