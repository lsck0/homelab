{ config, nasMount, ... }: {
  networking.hostName = "vm-111";

  fileSystems = nasMount "/var/lib/bitwarden_rs" "vaultwarden";

  sops.secrets.vaultwarden-oidc-secret = {};
  sops.templates."vaultwarden.env".content = ''
    SSO_CLIENT_SECRET=${config.sops.placeholder.vaultwarden-oidc-secret}
  '';

  services.vaultwarden = {
    enable = true;
    environmentFile = config.sops.templates."vaultwarden.env".path;
    config = {
      ROCKET_ADDRESS = "0.0.0.0";
      ROCKET_PORT = 8080;
      SIGNUPS_ALLOWED = false;
      DOMAIN = "https://vault.lsck0.dev";
      WEBSOCKET_ENABLED = true;
      SENDS_ALLOWED = true;
      EMERGENCY_ACCESS_ALLOWED = true;
      SHOW_PASSWORD_HINT = false;
      SSO_ENABLED = true;
      SSO_CLIENT_ID = "vaultwarden";
      SSO_AUTHORITY = "https://auth.lsck0.dev/application/o/vaultwarden/";
      SSO_PKCE = true;
      SSO_SIGNUPS_MATCH_EMAIL = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
