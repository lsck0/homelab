{ config, lib, inventory, ... }:
let
  # "vm-136" -> the inventory entry for 135 (address from src/lib.tf); null for hosts outside
  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  vm = if match == null then null else inventory.${builtins.head match} or null;

  cfg = config.homelab.ingressOnly;

  # who may talk to a guarded port.
  trustedSources = [
    "127.0.0.0/8"
    "10.88.0.0/16"     # podman default bridge
    "172.16.0.0/12"    # docker bridges
    "10.100.0.100/32"
    "10.200.0.200/32"
    "10.100.0.103/32"
    # The prober.
    "10.100.0.105/32"
    "10.100.0.114/32"
  ]
  # its own address: a container that calls a sibling by the VM's IP is not
  # coming from the bridge subnet.
  ++ lib.optional (vm != null) "${vm.ip}/32"
  ++ cfg.extraSources;
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
    (lib.mkIf (vm != null) {
      networking.useDHCP = lib.mkDefault false;
      networking.interfaces.eth0.ipv4.addresses = [{ address = vm.ip; prefixLength = vm.prefix; }];
      networking.defaultGateway = { address = vm.gateway; interface = "eth0"; };
      networking.nameservers = [ vm.gateway ];

      # a fresh VM boots as "nixos"; switching does not rename the running kernel
      system.activationScripts.hostname = "echo ${config.networking.hostName} > /proc/sys/kernel/hostname";

      # network-setup adds the default route and gives up permanently if the interface
      systemd.services.network-setup = {
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    })

    (lib.mkIf (cfg.ports != [ ]) {
      assertions = [
        {
          assertion = !(lib.elem 22 cfg.ports) && !(lib.elem 9100 cfg.ports);
          message = "homelab.ingressOnly.ports must not contain 22 or 9100: SSH and node-exporter are the recovery path.";
        }
        {
          # the rules below are iptables.
          assertion = !config.networking.nftables.enable;
          message = "homelab.ingressOnly uses networking.firewall.extraCommands (iptables); port this module to extraInputRules before enabling networking.nftables on ${config.networking.hostName}.";
        }
      ];

      # own chain jumped into at the top of nixos-fw
      networking.firewall.extraCommands = ''
        iptables -N homelab-ingress 2>/dev/null || iptables -F homelab-ingress
        ${lib.concatMapStrings (s: ''
          iptables -A homelab-ingress -s ${s} -j RETURN
        '') trustedSources}
        ${lib.concatMapStrings (p: ''
          ${lib.concatMapStrings (s: ''
            iptables -A homelab-ingress -p tcp --dport ${toString p} -s ${s} -j RETURN
          '') (cfg.portSources.${toString p} or [])}
          iptables -A homelab-ingress -p tcp --dport ${toString p} -j nixos-fw-refuse
        '') cfg.ports}
        iptables -A homelab-ingress -j RETURN
        iptables -D nixos-fw -j homelab-ingress 2>/dev/null || true
        iptables -I nixos-fw 1 -j homelab-ingress

        # Same guard again in mangle PREROUTING, which is the only place that
        # sees a published container port. nixos-fw is INPUT, but podman
        # publishes with a netavark DNAT, so the packet is forwarded to the
        # container and never traverses INPUT: FileBrowser (FB_NOAUTH) and the
        # registry (anonymous push) were reachable from the whole house.
        # PREROUTING runs before that DNAT, so it catches both paths.
        iptables -t mangle -N homelab-ingress-pre 2>/dev/null || iptables -t mangle -F homelab-ingress-pre
        ${lib.concatMapStrings (s: ''
          iptables -t mangle -A homelab-ingress-pre -s ${s} -j RETURN
        '') trustedSources}
        ${lib.concatMapStrings (p: ''
          ${lib.concatMapStrings (s: ''
            iptables -t mangle -A homelab-ingress-pre -p tcp --dport ${toString p} -s ${s} -j RETURN
          '') (cfg.portSources.${toString p} or [])}
          iptables -t mangle -A homelab-ingress-pre -p tcp --dport ${toString p} -j DROP
        '') cfg.ports}
        iptables -t mangle -A homelab-ingress-pre -j RETURN
        iptables -t mangle -D PREROUTING -j homelab-ingress-pre 2>/dev/null || true
        iptables -t mangle -I PREROUTING 1 -j homelab-ingress-pre
      '';

      networking.firewall.extraStopCommands = ''
        iptables -D nixos-fw -j homelab-ingress 2>/dev/null || true
        iptables -F homelab-ingress 2>/dev/null || true
        iptables -X homelab-ingress 2>/dev/null || true
        iptables -t mangle -D PREROUTING -j homelab-ingress-pre 2>/dev/null || true
        iptables -t mangle -F homelab-ingress-pre 2>/dev/null || true
        iptables -t mangle -X homelab-ingress-pre 2>/dev/null || true
      '';
    })
  ];
}
