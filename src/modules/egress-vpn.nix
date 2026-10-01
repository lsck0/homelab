{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.egress.vpn;
  endpointHost = lib.head (lib.splitString ":" cfg.endpoint);
in
{
  # one router tunnel for every via = "vpn" member
  options.homelab.egress.vpn = {
    enable = lib.mkEnableOption "a shared WireGuard exit for egress.nix members";

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Its own key: two clients cannot share one, and sharing breaks whichever connected first.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.2.0.3/32";
      description = "The address the provider assigned this client.";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "The server's WireGuard public key.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "89.222.96.158:51820";
      description = "host:port. An address, not a name - DNS is what the tunnel is waiting on.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.2.0.1";
      description = "Provider gateway. Needs its own main-table route, or NAT-PMP goes out the WAN and fails.";
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
      peers = [{
        publicKey = cfg.publicKey;
        allowedIPs = [ "0.0.0.0/0" ];
        endpoint = cfg.endpoint;
        # router sits behind the fritzbox nat
        persistentKeepalive = 25;
      }];
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

    # the router blackhole is the killswitch
    systemd.services.wireguard-wg-egress.unitConfig.StartLimitIntervalSec = 0;
    systemd.services.wireguard-wg-egress.serviceConfig = {
      Restart = "on-failure";
      RestartSec = 10;
    };

    assertions = [{
      assertion = endpointHost != "" && (builtins.match "[0-9.]+" endpointHost) != null;
      message = "homelab.egress.vpn.endpoint must be an address, not a name (got ${endpointHost}).";
    }];
  };
}
