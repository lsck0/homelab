{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.vpn;
  endpointHost = lib.head (lib.splitString ":" cfg.endpoint);
in
{
  # A WireGuard tunnel that the whole VM egresses through, with the LAN kept
  # off it and no way out if the tunnel is down.
  #
  # The killswitch is the absence of a route rather than a firewall rule:
  # networking.defaultGateway is removed, so the only default route is the one
  # wg0 installs when it comes up. Nothing has to notice the tunnel dropping -
  # there is simply nowhere for a packet to go. A rule that has to fire is a
  # rule that can fail to fire.
  #
  # Written for qBittorrent on vm-112, where the point is that the swarm sees
  # the VPN and not the house.
  options.homelab.vpn = {
    enable = lib.mkEnableOption "egress through a WireGuard tunnel";

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "File holding the client's WireGuard private key.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      example = "10.2.0.2/32";
      description = "The address the provider assigned this client.";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      description = "The server's WireGuard public key.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "89.222.96.158:51820";
      description = ''
        host:port of the server. An address, not a name: resolving it would
        need DNS, and DNS is one of the things that goes through the tunnel.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.str;
      example = "10.2.0.1";
      description = ''
        The resolver inside the tunnel. Using the LAN resolver instead would
        hand every tracker hostname to the house's DNS and out from its
        address, which is most of what the tunnel is for.
      '';
    };

    lanGateway = lib.mkOption {
      type = lib.types.str;
      example = "10.100.0.1";
      description = ''
        The router on the LAN. Still needed after the default route is taken
        away: the tunnel's own endpoint has to be reachable without it.
      '';
    };

    lanRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.200.0.0/24" ];
      description = ''
        Off-link prefixes that must keep using the LAN rather than the tunnel.
        The VM's own subnet needs no entry - the kernel routes it on-link from
        the interface address - so this is for anything reached through the
        router, and for whatever is used to log in and fix this when it breaks.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The leak, removed. Everything else here only matters because this is
    # gone: with a LAN default route in place, traffic would quietly fall back
    # to it the moment wg0 went down.
    networking.defaultGateway = lib.mkForce null;
    networking.nameservers = lib.mkForce [ cfg.dns ];

    # IPv6 has no route through this tunnel, and a host that can reach the
    # internet over IPv6 while IPv4 is tunnelled is not behind a tunnel.
    networking.enableIPv6 = false;
    boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;

    networking.interfaces.eth0.ipv4.routes =
      # The endpoint itself must not go through the tunnel, or the handshake
      # is routed into the thing it is trying to establish. Static rather than
      # added in postSetup, because it has to exist before the first handshake
      # and there is no default route to fall back on.
      [{ address = endpointHost; prefixLength = 32; via = cfg.lanGateway; }]
      ++ map
        (net: {
          address = lib.head (lib.splitString "/" net);
          prefixLength = lib.toInt (lib.last (lib.splitString "/" net));
          via = cfg.lanGateway;
        })
        cfg.lanRoutes;

    networking.wireguard.enable = true;
    networking.wireguard.interfaces.wg0 = {
      ips = [ cfg.address ];
      privateKeyFile = toString cfg.privateKeyFile;
      # 0.0.0.0/0 as a route would replace the endpoint route as well. The
      # default route is installed by hand below instead.
      allowedIPsAsRoutes = false;
      peers = [{
        publicKey = cfg.publicKey;
        allowedIPs = [ "0.0.0.0/0" ];
        endpoint = cfg.endpoint;
        # the tunnel sits behind the house NAT, so it has to keep itself alive
        persistentKeepalive = 25;
      }];
      postSetup = ''
        ${pkgs.iproute2}/bin/ip route replace default dev wg0
      '';
      postShutdown = ''
        ${pkgs.iproute2}/bin/ip route del default dev wg0 || true
      '';
    };
  };
}
