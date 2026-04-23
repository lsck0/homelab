{ nasMount, ... }: {
  networking.hostName = "vm-111";

  # Resolve auth.internal directly to authentik VM
  networking.hosts."10.100.0.101" = [ "auth.internal" ];

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
      SSO_ENABLED = true;
      SSO_CLIENT_ID = "vaultwarden";
      SSO_CLIENT_SECRET = "vaultwarden-oidc-secret-changeme";
      SSO_AUTHORITY = "http://auth.internal/application/o/vaultwarden/";
      SSO_PKCE = true;
      SSO_SIGNUPS_MATCH_EMAIL = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
