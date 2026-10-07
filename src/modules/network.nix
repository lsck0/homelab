# a guest's place in the lab: its name and static address from its own instance record, and the ingress guard on
# the ports only its zone's ingress may reach
#
# Every lab host gets its instance record (modules/lab) as the argument `instance`; its hostname, vmid, zone and
# services come from there. The install images and the router's lan-side tests have none (null).
#
# The guard (homelab.ingressOnly) is one nftables table, homelab-ingress, hooked into prerouting ahead of every
# dnat, so a podman- or docker-published port is guarded like a native one. Trusted on every guarded port:
# loopback, the guest's own address (containers calling siblings through it), its zone's ingress and, unless
# trustContainers is off, whatever enters from the host's own container bridges (by interface: a container range
# arriving on eth0 is a neighbour's spoof). Anyone else needs a grant: the guest's instance.nix `grants`, or a line
# in modules/flows.nix `guards` for what spans the lab; flows.nix holds both.
#
# The table is its own, not the firewall's: a firewall reload or stop leaves it in place, so the guard never fails
# open. Where the host runs nixos' nftables firewall the table lives in networking.nftables.tables (that service
# flushes the ruleset and reloads its tables together); elsewhere a oneshot loads it with `nft -f`, atomically.
# Rejected: iptables chains rebuilt by networking.firewall.extraCommands, which a restart rebuilds with a window
# and a stopped firewall deletes.
{ config, lib, pkgs, inventory, site, catalog, lab, instance, ... }:
let
  net = import ./net.nix { inherit lib inventory site; };
  flows = import ./flows.nix {
    inherit lib net inventory catalog lab;
    nasClients = throw "modules/network.nix renders the guards only, which name no nas client";
  };

  # the router is no guest of a zone: its own main.nix addresses it
  vm = if instance == null || instance.zone == "router" then null else inventory.${instance.id};
  vmId = if vm == null then null else instance.id;
  zone = if vm == null then null else net.zones.${instance.zone};

  cfg = config.homelab.ingressOnly;
  tableName = "homelab-ingress";

  # podman's bridges (podman0, one per network) and docker's (docker0, br-<id> per user network)
  containerInterfaces = [ "podman*" "docker0" "br-*" ];
  # never guarded: a mistake in the guard can always be undone over ssh, and the scrape shows it
  recoveryPorts = [ net.ports.ssh net.ports.nodeExporter ];

  trusted = [ "127.0.0.0/8" ]
    ++ lib.optional (zone != null && zone.ingress != null && zone.ingress != vmId) (net.hostSource zone.ingress)
    ++ lib.optional (vm != null) (net.hostSource vmId);

  # the guest's own services: every port open, an http or lab-only tcp one guarded unless it says why; a port the
  # router forwards from the house's public address answers the world
  services = if vm == null then [ ] else lib.attrValues instance.config.services;
  portsOf = protocol: lib.unique (map (s: s.port) (lib.filter (s: s.protocol == protocol) services));
  isGuarded = s: s.off.guard == null && (s.protocol == "http" || (s.protocol == "tcp" && s.publicPort == null));
  guardedPorts = lib.unique (map (s: s.port) (lib.filter isGuarded services));

  # port -> sources: every guard onto this guest, its instance.nix grants among them (modules/flows.nix `guards`)
  grants = lib.filter (g: g.to == vmId) flows.guards;
  allowed = lib.zipAttrsWith (_: lib.concatLists)
    (lib.concatMap (g: map (port: { ${toString port} = map (lab.sourceOf instance.zone) g.from; }) g.tcp) grants);

  # one rule per source: an anonymous set refuses overlapping prefixes (a /32 inside a granted subnet)
  sourceRules = match: sources: lib.concatMapStrings (source: "    ${match}ip saddr ${source} return\n") (lib.unique sources);

  table = ''
    chain prerouting {
      # before conntrack's dnat (priority dstnat), so a published container port is matched by the port it was
      # published on
      type filter hook prerouting priority mangle; policy accept;
      # replies and flows admitted when they began
      ct state { established, related } return
  '' + sourceRules "" cfg.trusted
    + lib.optionalString cfg.trustContainers (lib.concatMapStrings (i: "    iifname \"${i}\" return\n") containerInterfaces)
    + lib.concatMapStrings (port: sourceRules "tcp dport ${toString port} " (cfg.allowed.${toString port} or [ ])) (lib.unique cfg.ports)
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
    default = vmId;
    description = "The guest's vmid, from its instance record; null on the router and the install images.";
  };

  options.homelab.ingressOnly = {
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        TCP ports that only the zone's ingress, loopback and the granted sources may reach: an app whose own login is
        off because Authelia gates its route is otherwise one direct call away. SSH and node-exporter are never guarded.
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
      description = "Sources trusted on every guarded port; the laws read the rendered guard here.";
    };

    allowed = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      readOnly = true;
      internal = true;
      default = allowed;
      description = "Guarded port -> the sources granted it (instance.nix `grants`, modules/flows.nix `guards`).";
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
