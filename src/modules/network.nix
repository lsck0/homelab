{ config, lib, inventory, ... }:
let
  # "vm-136" -> its inventory entry, else null
  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  vm = if match == null then null else inventory.${builtins.head match} or null;

  cfg = config.homelab.ingressOnly;

  # who may reach a guarded port
  trustedSources = [
    "127.0.0.0/8"
  ]
  # containers calling their host's other services; a swarm node runs strangers' containers and trusts none
  ++ lib.optionals cfg.trustContainers [
    "10.88.0.0/16"     # podman default bridge
    "172.16.0.0/12"    # docker bridges
  ]
  ++ [
    # the internal ingress; the dmz one gets per-port sources, it must not reach every guarded port
    "10.100.0.100/32"
    "10.100.0.103/32"
    # the prober
    "10.100.0.105/32"
    "10.100.0.114/32"
  ]
  # containers calling siblings via the vm ip
  ++ lib.optional (vm != null) "${vm.ip}/32"
  ++ cfg.extraSources;

  # the same guard twice: in INPUT, and again pre-dnat since podman-published ports skip INPUT
  guards = [
    { table = "filter"; parent = "nixos-fw"; chain = "homelab-ingress"; deny = "nixos-fw-refuse"; }
    { table = "mangle"; parent = "PREROUTING"; chain = "homelab-ingress-pre"; deny = "DROP"; }
  ];
  guardStart = { table, parent, chain, deny }: let ipt = "iptables -t ${table}"; in ''
    ${ipt} -N ${chain} 2>/dev/null || ${ipt} -F ${chain}
    ${lib.concatMapStrings (s: ''
      ${ipt} -A ${chain} -s ${s} -j RETURN
    '') trustedSources}
    ${lib.concatMapStrings (p: ''
      ${lib.concatMapStrings (s: ''
        ${ipt} -A ${chain} -p tcp --dport ${toString p} -s ${s} -j RETURN
      '') (cfg.portSources.${toString p} or [])}
      ${ipt} -A ${chain} -p tcp --dport ${toString p} -j ${deny}
    '') cfg.ports}
    ${ipt} -A ${chain} -j RETURN
    ${ipt} -D ${parent} -j ${chain} 2>/dev/null || true
    ${ipt} -I ${parent} 1 -j ${chain}
  '';
  guardStop = { table, parent, chain, ... }: let ipt = "iptables -t ${table}"; in ''
    ${ipt} -D ${parent} -j ${chain} 2>/dev/null || true
    ${ipt} -F ${chain} 2>/dev/null || true
    ${ipt} -X ${chain} 2>/dev/null || true
  '';
in {
  options.homelab.ingressOnly = {
    ports = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        TCP ports that only the ingress (and the monitoring/ops hosts) may
        reach. Use it for apps whose built-in login is disabled because
        Authelia gates their Traefik route: without this, any host on the LAN
        could skip Authelia by calling the VM's port directly.

        SSH (22) and node-exporter (9100) are deliberately never guarded, so a
        mistake here can always be undone over SSH.
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
      description = ''
        Extra CIDRs allowed to reach one specific port, keyed by port number.

        For ports where the risk differs per port on the same host: Grafana's
        :80 trusts the Remote-User header and must stay behind the ingress,
        while Prometheus on :9090 is read-only telemetry that a desktop widget
        can reasonably scrape from the LAN.
      '';
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

      # switching does not rename the running kernel
      # read-only in an unprivileged container; it takes the name at start
      system.activationScripts.hostname = lib.mkIf (!config.boot.isContainer)
        "echo ${config.networking.hostName} > /proc/sys/kernel/hostname";

      # retry forever if eth0 is not up yet; scripted networking only (lxc uses networkd)
      systemd.services.network-setup = lib.mkIf (!config.networking.useNetworkd) {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    # netavark enables forwarding at runtime, 60-nixos.conf resets it on every systemd-sysctl restart
    (lib.mkIf config.virtualisation.podman.enable {
      boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
    })

    (lib.mkIf (cfg.ports != [ ]) {
      assertions = [
        {
          assertion = !(lib.elem 22 cfg.ports) && !(lib.elem 9100 cfg.ports);
          message = "homelab.ingressOnly.ports must not contain 22 or 9100: SSH and node-exporter are the recovery path.";
        }
        {
          # the rules below are iptables
          assertion = !config.networking.nftables.enable;
          message = "homelab.ingressOnly uses networking.firewall.extraCommands (iptables); port this module to extraInputRules before enabling networking.nftables on ${config.networking.hostName}.";
        }
      ];

      # own chain at the top of nixos-fw and of mangle PREROUTING
      networking.firewall.extraCommands = lib.concatMapStrings guardStart guards;
      networking.firewall.extraStopCommands = lib.concatMapStrings guardStop guards;
    })
  ];
}
