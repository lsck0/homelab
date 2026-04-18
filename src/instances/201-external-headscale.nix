{ ... }: {
  networking.hostName = "vm-201";

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = 80;
    settings = {
      server_url = "https://hs.lsck0.dev";
      dns = {
        base_domain = "headscale.internal";
        nameservers.global = [ "10.200.0.1" ];
      };
      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
