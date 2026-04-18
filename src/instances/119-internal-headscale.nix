{ ... }: {
  networking.hostName = "vm-119";

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = 80;
    settings = {
      server_url = "https://hs.internal.local";
      dns = {
        base_domain = "hs.internal.local";
        nameservers.global = [ "10.100.0.1" ];
      };
      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
