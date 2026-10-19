# a guest's place in the lab: its name and static address from its own instance record, its firewall's openings, and
# the guard on the ports only named sources may reach
#
# the firewall opens ssh and node-exporter, the guest's services' ports and what its main.nix opens; a shared module
# opening more names it in homelab.openings, which the guest's instance.nix allows in `on`.
# security: the guard is one nftables table hooked into prerouting ahead of every dnat, so a container-published port
# is guarded like a native one. The host's own calls pass by interface. ssh and node-exporter, the recovery path,
# answer their own sources alone (modules/flows.nix `recovery`), never a neighbour, the ingress or a container. Every
# other guarded port trusts its zone's ingress and the host's container bridges by interface (a container range
# arriving on eth0 is a neighbour's spoof); anyone else needs a grant. Every refusal is logged, rate limited.
# The table is its own, so a firewall reload or stop leaves it in place and the guard never fails open.
# Rejected: iptables chains rebuilt by networking.firewall.extraCommands, which a restart rebuilds with a window
# and a stopped firewall deletes.
{
  config,
  lib,
  pkgs,
  inventory,
  site,
  catalog,
  lab,
  instance,
  ...
}:
let
  net = import ./net.nix { inherit lib inventory site; };
  flows = import ./flows.nix {
    inherit
      lib
      net
      inventory
      catalog
      lab
      ;
    nasClients = throw "modules/network.nix renders the guards only, which name no nas client";
  };

  # the router is no guest of a zone: its own main.nix addresses it
  vm = if instance == null || instance.zone == "router" then null else inventory.${instance.id};
  vmId = if vm == null then null else instance.id;
  zone = if vm == null then null else net.zones.${instance.zone};

  cfg = config.homelab.ingressOnly;
  tableName = "homelab-ingress";

  # podman's bridges (podman0, one per network) and docker's (docker0, br-<id> per user network)
  containerInterfaces = [
    "podman*"
    "docker0"
    "br-*"
  ];
  recoveryPorts = [
    net.ports.ssh
    net.ports.nodeExporter
  ];
  # port -> the sources admitted; null on the router and the install images, whose ssh the first deploy needs
  recovery =
    if vm == null then
      null
    else
      lib.mapAttrs' (
        name: sources: lib.nameValuePair (toString net.ports.${name}) (map (lab.sourceOf instance.zone) sources)
      ) (flows.recovery vmId);

  trusted = lib.optional (zone != null && zone.ingress != null && zone.ingress != vmId) (net.hostSource zone.ingress);

  # the guest's own services: every port open, an http or lab-only tcp one guarded where it opts in; a port the
  # router forwards from the house's public address answers the world
  services = if vm == null then [ ] else lib.attrValues instance.config.services;
  portsOf = protocol: lib.unique (map (s: s.port) (lib.filter (s: s.protocol == protocol) services));
  isGuarded = s: lib.elem "guard" s.on && (s.protocol == "http" || (s.protocol == "tcp" && s.publicPort == null));
  guardedPorts = lib.unique (map (s: s.port) (lib.filter isGuarded services));
  # an exporter a service declares answers vm-103's grant (modules/flows.nix metricsGrants), never its neighbours
  metricsPorts = lib.unique (
    lib.concatMap (s: map (m: m.port) (lib.attrValues s.metrics)) (lib.filter (s: lib.elem "metrics" s.on) services)
  );

  # port -> sources: every guard onto this guest, its instance.nix grants among them (modules/flows.nix `guards`); a
  # grant of ssh extends the recovery path instead
  grants = lib.filter (g: g.to == vmId) flows.guards;
  allowed = builtins.zipAttrsWith (_: lib.concatLists) (
    lib.concatMap (
      g: map (port: { ${toString port} = map (lab.sourceOf instance.zone) g.from; }) (lib.subtractLists recoveryPorts g.tcp)
    ) grants
  );

  # one rule per source: an anonymous set refuses overlapping prefixes (a /32 inside a granted subnet)
  sourceRules =
    match: sources: lib.concatMapStrings (source: "    ${match}ip saddr ${source} return\n") (lib.unique sources);
  portRules = allowed: lib.concatStrings (lib.mapAttrsToList (port: sourceRules "tcp dport ${port} ") allowed);
  # bounds the journal under a scan
  refusalLogPerMinute = 30;
  refuseRule = ports: ''
    tcp dport { ${
      lib.concatMapStringsSep ", " toString ports
    } } ct state new limit rate ${toString refusalLogPerMinute}/minute log prefix "guard-refused: " level info
    tcp dport { ${lib.concatMapStringsSep ", " toString ports} } counter drop
  '';

  table = ''
    chain prerouting {
      # before conntrack's dnat (priority dstnat), so a published container port is matched by the port it was
      # published on
      type filter hook prerouting priority mangle; policy accept;
      # replies and flows admitted when they began
      ct state { established, related } return
  ''
  # the host's own calls, to any of its addresses
  + "    iifname \"lo\" return\n"
  + lib.optionalString (cfg.recovery != null) (portRules cfg.recovery + refuseRule recoveryPorts)
  + lib.optionalString (cfg.ports != [ ]) (
    sourceRules "" cfg.trusted
    + lib.optionalString cfg.trustContainers (lib.concatMapStrings (i: "    iifname \"${i}\" return\n") containerInterfaces)
    + portRules (lib.genAttrs (map toString (lib.unique cfg.ports)) (port: cfg.allowed.${port} or [ ]))
    + refuseRule (lib.unique cfg.ports)
  )
  + "}\n";
  guarded = cfg.ports != [ ] || cfg.recovery != null;

  # create, delete and define in one transaction: the old table is replaced atomically, never absent
  tableFile = pkgs.writeText "${tableName}.nft" (
    ''
      table inet ${tableName}
      delete table inet ${tableName}
    ''
    + lib.optionalString guarded ''
      table inet ${tableName} {
      ${table}
      }
    ''
  );
in
{
  options.homelab.vmid = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    default = vmId;
    description = "The guest's vmid, from its instance record; null on the router and the install images.";
  };

  options.homelab.on = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = if instance == null then [ ] else instance.config.on;
    description = "What the guest opts into for itself, from its instance record (modules/instance-schema.nix `on`).";
  };

  options.homelab.openings = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Opening -> the ports a shared module running here opens beyond the guest's services; each must be in homelab.on.";
  };

  options.homelab.ingressOnly = {
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        TCP ports that only the zone's ingress, loopback and the granted sources may reach: an app whose own login is
        off because Authelia gates its route is otherwise one direct call away. SSH and node-exporter are the
        recovery path's (homelab.ingressOnly.recovery), never these.
      '';
    };

    trustContainers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Let this host's container bridges reach every guarded port.";
    };

    trusted = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = trusted;
      description = "Sources beyond the host itself trusted on every guarded port; the laws read the rendered guard here.";
    };

    allowed = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      readOnly = true;
      internal = true;
      default = allowed;
      description = "Guarded port -> the sources granted it (instance.nix `grants`, modules/flows.nix `guards`).";
    };

    recovery = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf (lib.types.listOf lib.types.str));
      readOnly = true;
      internal = true;
      default = recovery;
      description = "SSH's and node-exporter's port -> the sources they admit (modules/flows.nix `recovery`); null: open.";
    };
  };

  config = lib.mkMerge [
    {
      # the install images and the stand-ins of a test name no instance
      _module.args.instance = lib.mkDefault null;
      # the guest's own address, for services that hand it to their containers
      _module.args.hostIp = if vm != null then vm.ip else null;
    }

    (lib.mkIf (instance != null) { networking.hostName = instance.config.hostName; })

    (lib.mkIf (vm != null) {
      networking.useDHCP = lib.mkDefault false;
      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = vm.ip;
          prefixLength = vm.prefix;
        }
      ];
      networking.defaultGateway = {
        address = vm.gateway;
        interface = "eth0";
      };
      networking.nameservers = [ vm.gateway ];

      # switching does not rename the running kernel; read-only in an unprivileged container, it takes the name at start
      system.activationScripts.hostname = lib.mkIf (
        !config.boot.isContainer
      ) "echo ${config.networking.hostName} > /proc/sys/kernel/hostname";

      # eth0 may come up after the unit; scripted networking only (lxc uses networkd)
      systemd.services.network-setup = lib.mkIf (!config.networking.useNetworkd) {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      homelab.ingressOnly.ports = guardedPorts ++ metricsPorts;
      networking.firewall.allowedTCPPorts = portsOf "http" ++ portsOf "tcp" ++ metricsPorts;
      networking.firewall.allowedUDPPorts = portsOf "udp";
    })

    # netavark enables forwarding at runtime, 60-nixos.conf resets it on every systemd-sysctl restart
    (lib.mkIf config.virtualisation.podman.enable {
      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
    })

    {
      assertions = [
        {
          assertion = lib.intersectLists recoveryPorts cfg.ports == [ ];
          message = "homelab.ingressOnly.ports must not contain ${toString recoveryPorts}: SSH and node-exporter admit the recovery sources alone.";
        }
      ]
      # a host without an instance record (an install image, a test's stand-in) has no instance.nix to allow them in
      ++ lib.optionals (instance != null) (
        lib.mapAttrsToList (opening: ports: {
          assertion = lib.elem opening config.homelab.on;
          message = "${config.networking.hostName} opens ${ports}, which its instance.nix allows with \"${opening}\" in `on`.";
        }) config.homelab.openings
      );
    }

    (lib.mkIf (config.networking.nftables.enable && guarded) {
      networking.nftables.tables.${tableName} = {
        family = "inet";
        content = table;
      };
    })

    # every guest carries the unit, so dropping the last guarded port deletes the table instead of orphaning it
    (lib.mkIf (!config.networking.nftables.enable) {
      systemd.services.${tableName} = {
        description = "Guard: ssh, node-exporter and the guarded ports admit only their own sources";
        # in place before any interface is up
        wantedBy = [ "sysinit.target" ];
        before = [
          "network-pre.target"
          "sysinit.target"
        ];
        wants = [ "network-pre.target" ];
        after = [ "systemd-modules-load.service" ];
        unitConfig.DefaultDependencies = false;
        restartTriggers = [ tableFile ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.nftables}/bin/nft -f ${tableFile}";
        };
      };
    })
  ];
}
