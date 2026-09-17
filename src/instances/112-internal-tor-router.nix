{ ... }: {
  networking.hostName = "vm-112";

  # SOCKS5 gateway into the Tor network for internal VMs. Client only -
  # this node relays nothing. The public non-exit relay is vm-202.
  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;

    client = {
      enable = true;
      socksListenAddress = {
        addr = "10.100.0.112";
        port = 9050;
        # per-destination circuit isolation is the usual client default, but a
        # torrent client opens connections to hundreds of peers at once and
        # would build a circuit for each. Keep connections on shared circuits.
        IsolateDestAddr = false;
      };
    };

    settings = {
      # only the internal LAN may use this proxy.
      SocksPolicy = [ "accept 10.100.0.0/24" "reject *" ];
      # DNS resolver for callers that cannot resolve through SOCKS5 themselves.
      DNSPort = [{ addr = "10.100.0.112"; port = 9053; }];
      AutomapHostsOnResolve = true;
      ClientUseIPv6 = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 9050 ];
  networking.firewall.allowedUDPPorts = [ 9053 ];
}
