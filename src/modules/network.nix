# a guest's place in the lab: its static address from the inventory, and the ingress guard on the ports only its
# zone's ingress may reach
#
# The guard (homelab.ingressOnly) is one nftables table, homelab-ingress, hooked into prerouting ahead of every
# dnat, so a podman- or docker-published port is guarded like a native one. Trusted on every guarded port:
# loopback, the guest's own address (containers calling siblings through it), its zone's ingress and, unless
# trustContainers is off, the local container bridges. Anyone else needs a grant: `portSources` here, or a line in
# modules/flows.nix `guards`, which this module renders for the guest it runs on.
#
# The table is its own, not the firewall's: a firewall reload or stop leaves it in place, so the guard never fails
# open. Where the host runs nixos' nftables firewall the table lives in networking.nftables.tables (that service
# flushes the ruleset and reloads its tables together); elsewhere a oneshot loads it with `nft -f`, atomically.
# Rejected: iptables chains rebuilt by networking.firewall.extraCommands, which a restart rebuilds with a window
# and a stopped firewall deletes.
{ config, lib, pkgs, inventory, site, catalog, lab, ... }:
let
  net = import ./net.nix { inherit lib inventory site; };
  flows = import ./flows.nix {
    inherit lib net inventory catalog lab;
    appsCatalog = config.homelab.appsCatalog;
    nasClients = throw "modules/network.nix renders the guards only, which name no nas client";
  };

  vmId = config.homelab.vmid;
  vm = if vmId == null then null else inventory.${vmId} or null;
  zone = if vm == null then null else net.zones.${vm.type} or null;

  cfg = config.homelab.ingressOnly;
  tableName = "homelab-ingress";

  # podman's default bridge and docker's: the host's own containers calling its other services
  containerRanges = [ "10.88.0.0/16" "172.16.0.0/12" ];
  # never guarded: a mistake in the guard can always be undone over ssh, and the scrape shows it
  recoveryPorts = [ net.ports.ssh net.ports.nodeExporter ];

  trustedSources = [ "127.0.0.0/8" ]
    ++ lib.optionals cfg.trustContainers containerRanges
    ++ lib.optional (zone != null && zone.ingress != null && zone.ingress != vmId) (net.hostSource zone.ingress)
    ++ lib.optional (vm != null) (net.hostSource vmId)
    ++ cfg.extraSources;

  # the guest's own services (instance.nix `services`): every port open, an http one's guarded unless it says why
  ownRoutes = lib.filter (r: toString r.vmid == vmId) (lib.attrValues lab.routes);
  portsOf = protocol: lib.unique (map (r: r.port) (lib.filter (r: r.protocol == protocol) ownRoutes));
  guardedPorts = lib.unique (map (r: r.port) (lib.filter (r: r.protocol == "http" && r.off.guard == null) ownRoutes));

  # flows.nix grants onto this guest: port -> sources
  grants = lib.foldl' (acc: g: lib.foldl' (acc': port: acc' // {
    ${toString port} = (acc'.${toString port} or [ ]) ++ map net.hostSource g.from;
  }) acc g.tcp) { } (lib.filter (g: g.to == vmId) flows.guards);

  # one rule per source: an anonymous set refuses overlapping prefixes (a /32 inside a granted subnet)
  sourceRules = match: sources: lib.concatMapStrings (source: "    ${match}ip saddr ${source} return\n") (lib.unique sources);

  table = ''
    chain prerouting {
      # before conntrack's dnat (priority dstnat), so a published container port is matched by the port it was
      # published on
      type filter hook prerouting priority mangle; policy accept;
      # replies and flows admitted when they began
      ct state { established, related } return
  '' + sourceRules "" trustedSources
    + lib.concatMapStrings (port: sourceRules "tcp dport ${toString port} " (cfg.portSources.${toString port} or [ ])) (lib.unique cfg.ports)
    + ''
      tcp dport { ${lib.concatMapStringsSep ", " toString (lib.unique cfg.ports)} } counter drop
    }
  '';

  # create, delete and define in one transaction: the old table is replaced atomically, never absent
  tableFile = pkgs.writeText "${tableName}.nft" (''
    table inet ${tableName}
    delete table inet ${tableName}
  '' + lib.optionalString (cfg.ports != [ ]) ''
    table inet ${tableName} {
    ${table}
    }
  '');
in {
  options.homelab.vmid = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    default = let match = builtins.match "vm-([0-9]+)" config.networking.hostName; in if match == null then null else lib.head match;
    description = "The guest's vmid, from its hostName vm-<vmid>; null on the router and the install images.";
  };

  options.homelab.ingressOnly = {
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        TCP ports that only the zone's ingress, loopback and the sources granted below may reach: an app whose own
        login is off because Authelia gates its route is otherwise one direct call away. SSH and node-exporter are
        never guarded.
      '';
    };

    trustContainers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Let this host's container bridges reach every guarded port.";
    };

    extraSources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional CIDRs allowed to reach every guarded port.";
    };

    portSources = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = lib.literalExpression ''{ "9090" = [ "192.168.178.0/24" ]; }'';
      description = "Extra CIDRs allowed to reach one port, keyed by port number; modules/flows.nix `guards` adds to it.";
    };
  };

  config = lib.mkMerge [
    # the guest's own address, for services that hand it to their containers
    { _module.args.hostIp = if vm != null then vm.ip else null; }

    (lib.mkIf (vm != null) {
      networking.useDHCP = lib.mkDefault false;
      networking.interfaces.eth0.ipv4.addresses = [{ address = vm.ip; prefixLength = vm.prefix; }];
      networking.defaultGateway = { address = vm.gateway; interface = "eth0"; };
      networking.nameservers = [ vm.gateway ];

      # switching does not rename the running kernel; read-only in an unprivileged container, it takes the name at start
      system.activationScripts.hostname = lib.mkIf (!config.boot.isContainer)
        "echo ${config.networking.hostName} > /proc/sys/kernel/hostname";

      # eth0 may come up after the unit; scripted networking only (lxc uses networkd)
      systemd.services.network-setup = lib.mkIf (!config.networking.useNetworkd) {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      homelab.ingressOnly.portSources = grants;
      homelab.ingressOnly.ports = guardedPorts;
      networking.firewall.allowedTCPPorts = portsOf "http" ++ portsOf "tcp";
      networking.firewall.allowedUDPPorts = portsOf "udp";
    })

    # netavark enables forwarding at runtime, 60-nixos.conf resets it on every systemd-sysctl restart
    (lib.mkIf config.virtualisation.podman.enable {
      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
    })

    {
      assertions = [{
        assertion = lib.intersectLists recoveryPorts cfg.ports == [ ];
        message = "homelab.ingressOnly.ports must not contain ${toString recoveryPorts}: SSH and node-exporter are the recovery path.";
      }];
    }

    (lib.mkIf (config.networking.nftables.enable && cfg.ports != [ ]) {
      networking.nftables.tables.${tableName} = { family = "inet"; content = table; };
    })

    # every guest carries the unit, so dropping the last guarded port deletes the table instead of orphaning it
    (lib.mkIf (!config.networking.nftables.enable) {
      systemd.services.${tableName} = {
        description = "Ingress guard: guarded ports reach only the zone's ingress and granted sources";
        # in place before any interface is up
        wantedBy = [ "sysinit.target" ];
        before = [ "network-pre.target" "sysinit.target" ];
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
