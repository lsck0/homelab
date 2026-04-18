{ nasMount, ... }: {
  networking.hostName = "vm-110";

  fileSystems = nasMount "/var/lib/bitwarden_rs" "vaultwarden";

  services.vaultwarden = {
    enable = true;
    config = {
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8080;
      SIGNUPS_ALLOWED = false;
      DOMAIN = "https://vault.internal";
      WEBSOCKET_ENABLED = true;
      SENDS_ALLOWED = true;
      EMERGENCY_ACCESS_ALLOWED = true;
      SHOW_PASSWORD_HINT = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
