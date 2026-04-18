{ ... }: {
  networking.hostName = "vm-112";

  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
