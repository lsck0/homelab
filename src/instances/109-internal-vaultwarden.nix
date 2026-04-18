{ ... }: {
  networking.hostName = "vm-109";

  services.vaultwarden = {
    enable = true;
    config = {
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8080;
      SIGNUPS_ALLOWED = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
