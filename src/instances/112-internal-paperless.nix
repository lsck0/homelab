{ ... }: {
  networking.hostName = "vm-112";

  services.paperless = {
    enable = true;
    address = "0.0.0.0";
    port = 8080;
    settings = {
      PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
      PAPERLESS_HTTP_REMOTE_USER_HEADER_NAME = "HTTP_X_AUTHENTIK_USERNAME";
      PAPERLESS_URL = "https://paperless.internal.local";
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://paperless.internal.local,https://paperless.lsck0.dev";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
