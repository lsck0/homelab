# the router's one wireguard exit for every instance whose egress is vpn (instance.nix `on`), over the first of its
# servers that answers
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.egress.vpn;
  hostOf = endpoint: lib.head (lib.splitString ":" endpoint);
  # any metric above the tunnel route's 0
  gatewayBlackholeMetric = 1000;
  # wireguard handshakes every 2 minutes on a live tunnel; past this one the server is gone
  handshakeStaleS = 180;
  failoverTextfile = "vpn_handshake";
  # one line per server: "<public key> <endpoint>", in the order they are tried
  serverList = pkgs.writeText "wg-egress-servers" (
    lib.concatMapStrings (server: "${server.publicKey} ${server.endpoint}\n") cfg.servers
  );
in
{
  options.homelab.egress.vpn = {
    enable = lib.mkEnableOption "a shared WireGuard exit for the instances whose egress is vpn";

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Its own key: two clients cannot share one, and sharing breaks whichever connected first.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.2.0.3/32";
      description = "The address the provider assigned this client.";
    };

    servers = lib.mkOption {
      type = lib.types.nonEmptyListOf (
        lib.types.submodule {
          options = {
            publicKey = lib.mkOption {
              type = lib.types.str;
              description = "The server's WireGuard public key.";
            };
            endpoint = lib.mkOption {
              type = lib.types.str;
              example = "89.222.96.158:51820";
              description = "host:port. An address, not a name: DNS is what the tunnel is waiting on.";
            };
          };
        }
      );
      description = "The provider's servers this key may use, the first one at start; a server without a handshake for ${toString handshakeStaleS}s gives way to the next.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.2.0.1";
      description = "Provider gateway. Needs its own main-table route, or NAT-PMP goes out the WAN and fails.";
    };

    dns = lib.mkOption {
      type = lib.types.str;
      default = cfg.gateway;
      description = "The provider's resolver inside the tunnel, which answers the members' dns so no name leaves through the house.";
    };

    table = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Routing table the exit's default route is installed in. Set by the router, which owns the mark that selects it.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.wireguard.enable = true;
    networking.wireguard.interfaces.wg-egress = {
      ips = [ cfg.address ];
      privateKeyFile = toString cfg.privateKeyFile;
      # 0.0.0.0/0 in main would tunnel everything
      allowedIPsAsRoutes = false;
      peers = [
        {
          inherit (lib.head cfg.servers) publicKey endpoint;
          allowedIPs = [ "0.0.0.0/0" ];
          # router sits behind the fritzbox nat
          persistentKeepalive = 25;
        }
      ];
      postSetup = ''
        ${pkgs.iproute2}/bin/ip route replace default dev wg-egress metric 1 table ${toString cfg.table}
        # provider gateway in main, see option
        ${pkgs.iproute2}/bin/ip route replace ${cfg.gateway}/32 dev wg-egress
      '';
      postShutdown = ''
        ${pkgs.iproute2}/bin/ip route del default dev wg-egress metric 1 table ${toString cfg.table} || true
        ${pkgs.iproute2}/bin/ip route del ${cfg.gateway}/32 dev wg-egress || true
      '';
    };

    # not a trusted interface: the router's own services stay closed to the provider side, forwarded peers pass as dnat

    # nat onto the provider-assigned address
    networking.nftables.tables.egress-nat = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat + 5; policy accept;
          oifname "wg-egress" masquerade
        }
      '';
    };

    # with the tunnel down the gateway's route above is gone: the provider's resolver and nat-pmp must then reach
    # nothing rather than leave through the house in the clear
    systemd.services.wg-egress-gateway-blackhole = {
      description = "Blackhole the VPN gateway outside the tunnel";
      wantedBy = [ "multi-user.target" ];
      before = [ "wireguard-wg-egress.service" ];
      after = [ "network-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # below the tunnel's own route (metric 0), so it only answers while that one is missing
      script = "${pkgs.iproute2}/bin/ip route replace blackhole ${cfg.gateway}/32 metric ${toString gatewayBlackholeMetric}";
    };

    # the router blackhole route and forward guard are the killswitch
    systemd.services.wireguard-wg-egress.unitConfig.StartLimitIntervalSec = 0;
    systemd.services.wireguard-wg-egress.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 10;
    };

    # the tunnel's one peer moves to the next server when its handshake goes stale; the age is a gauge either way
    homelab.textfiles = [ failoverTextfile ];
    systemd.services.wg-egress-failover = {
      description = "Move the VPN exit to the next server when its handshake is stale";
      after = [ "wireguard-wg-egress.service" ];
      path = [
        pkgs.wireguard-tools
        pkgs.coreutils
        pkgs.gawk
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        read -r peer handshake < <(wg show wg-egress latest-handshakes)
        age=$(( $(date +%s) - handshake ))
        metrics=${config.homelab.textfileDir}/${failoverTextfile}.prom
        printf '# TYPE homelab_vpn_handshake_age_seconds gauge\nhomelab_vpn_handshake_age_seconds %s\n' "$age" > "$metrics.tmp"
        mv "$metrics.tmp" "$metrics"
        (( age > ${toString handshakeStaleS} )) || exit 0
        count=$(wc -l < ${serverList})
        [ "$count" -gt 1 ] || exit 0
        current=$(awk -v key="$peer" '$1 == key { print NR }' ${serverList})
        read -r key endpoint < <(awk -v next_line=$(( ''${current:-0} % count + 1 )) 'NR == next_line' ${serverList})
        wg set wg-egress peer "$peer" remove peer "$key" endpoint "$endpoint" allowed-ips 0.0.0.0/0 persistent-keepalive 25
        echo "no handshake for ''${age}s: the exit moves to $endpoint"
      '';
    };
    systemd.timers.wg-egress-failover = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "1m";
      };
    };

    assertions = map (server: {
      assertion = builtins.match "[0-9.]+" (hostOf server.endpoint) != null;
      message = "homelab.egress.vpn.servers: an endpoint must be an address, not a name (got ${hostOf server.endpoint}).";
    }) cfg.servers;
  };
}
