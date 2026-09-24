{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.egress.vpn;
  endpointHost = lib.head (lib.splitString ":" cfg.endpoint);
in
{
  # The shared VPN exit: one WireGuard tunnel on the router that any VM listed
  # as via = "vpn" in modules/egress.nix leaves through.
  #
  # Different from modules/vpn.nix, which puts a tunnel inside one VM and sends
  # that VM's own traffic down it. This one carries *forwarded* traffic for
  # other machines, so it never touches the router's own default route - the
  # house still reaches the internet normally, and only marked packets are
  # steered into table `cfg.table`.
  #
  # It cannot replace modules/vpn.nix for qBittorrent. A shared exit has one
  # inbound forwarded port, so it cannot give every VM behind it a port of its
  # own, and an inbound port is most of why vm-112 has a tunnel at all.
  options.homelab.egress.vpn = {
    enable = lib.mkEnableOption "a shared WireGuard exit for egress.nix members";

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding this tunnel's WireGuard private key. Its own key, not the
        one vm-112 uses: two clients cannot share a key or an address, and
        pointing both at the same one breaks whichever connected first.
      '';
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
      description = ''
        host:port of the server. An address, not a name: resolving a name
        would need DNS at a point where the tunnel is what DNS is waiting on.
      '';
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.2.0.1";
      description = ''
        The provider's gateway inside the tunnel. Needs a route of its own in
        the main table: allowedIPsAsRoutes is off, so nothing here points at
        wg-egress except the egress table, and the router's own NAT-PMP lease
        request (scripts/protonvpn-port.sh) is locally generated and unmarked.
        Without it natpmpc sends to 10.2.0.1 through the WAN and gets
        "readnatpmpresponseorretry returned -7 (FAILED)".
      '';
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
      # Emphatically not as routes: a 0.0.0.0/0 route in the main table would
      # send the router's own traffic - and every VM's - down the tunnel. The
      # only default route this installs goes in the egress table.
      allowedIPsAsRoutes = false;
      peers = [{
        publicKey = cfg.publicKey;
        allowedIPs = [ "0.0.0.0/0" ];
        endpoint = cfg.endpoint;
        # the router is behind the FritzBox NAT
        persistentKeepalive = 25;
      }];
      postSetup = ''
        ${pkgs.iproute2}/bin/ip route replace default dev wg-egress metric 1 table ${toString cfg.table}
        # the provider's gateway, in the main table: see the option's comment.
        ${pkgs.iproute2}/bin/ip route replace ${cfg.gateway}/32 dev wg-egress
      '';
      postShutdown = ''
        ${pkgs.iproute2}/bin/ip route del default dev wg-egress metric 1 table ${toString cfg.table} || true
        ${pkgs.iproute2}/bin/ip route del ${cfg.gateway}/32 dev wg-egress || true
      '';
    };

    # The endpoint must not be reached through the tunnel, or the handshake is
    # routed into the thing it is establishing. The router's own default route
    # is untouched, so this only has to beat the egress table - which it does,
    # because the endpoint is matched in the main table before the mark rule
    # is ever consulted for the router's own packets.
    networking.firewall.trustedInterfaces = [ "wg-egress" ];

    # Traffic leaving the tunnel is NATed onto the address the provider gave.
    networking.nftables.tables.egress-nat = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat + 5; policy accept;
          oifname "wg-egress" masquerade
        }
      '';
    };

    # A member's packets must not survive the tunnel going away. The blackhole
    # default the router installs in this table is the floor; this only makes
    # the failure loud instead of silent.
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
