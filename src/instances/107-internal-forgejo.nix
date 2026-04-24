{ config, pkgs, nasMount, ... }: {
  networking.hostName = "vm-107";

  fileSystems = nasMount "/var/lib/forgejo" "forgejo"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets.forgejo-oidc-secret = {};

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo:7";
    ports = [ "80:3000" "2222:22" ];
    volumes = [ "/var/lib/forgejo:/data" ];
    extraOptions = [ "--add-host=auth.lsck0.dev:10.100.0.100" ];
    environment = {
      FORGEJO__server__HTTP_PORT = "3000";
      FORGEJO__server__ROOT_URL = "https://git.lsck0.dev/";
      FORGEJO__actions__ENABLED = "true";
      FORGEJO__service__DISABLE_REGISTRATION = "false";
      FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION = "true";
      FORGEJO__openid__ENABLE_OPENID_SIGNIN = "true";
      FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION = "true";
      FORGEJO__oauth2_client__ACCOUNT_LINKING = "auto";
      FORGEJO__oauth2_client__USERNAME = "nickname";
    };
  };

  # Configure OAuth2 auth source after Forgejo starts
  systemd.services.forgejo-oauth2-setup = {
    description = "Configure Forgejo OAuth2 with authentik";
    after = [ "podman-forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman pkgs.gawk pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for Forgejo API
      for i in $(seq 1 60); do
        if curl -sf http://127.0.0.1:80/api/v1/settings/api >/dev/null 2>&1; then break; fi
        sleep 2
      done

      OIDC_SECRET=$(cat ${config.sops.secrets.forgejo-oidc-secret.path})
      DISCOVER_URL="https://auth.lsck0.dev/application/o/forgejo-oidc/.well-known/openid-configuration"

      # Check if auth source already exists via CLI
      AUTH_ID=$(podman exec -u git forgejo forgejo admin auth list 2>/dev/null \
        | grep -w authentik | awk '{print $1}')

      if [ -n "$AUTH_ID" ]; then
        echo "OAuth2 source exists (id=$AUTH_ID), updating..."
        podman exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" \
          --secret "$OIDC_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          2>/dev/null || true
        exit 0
      fi

      # Create via Forgejo CLI inside container
      podman exec -u git forgejo forgejo admin auth add-oauth \
        --name authentik \
        --provider openidConnect \
        --key forgejo \
        --secret "$OIDC_SECRET" \
        --auto-discover-url "$DISCOVER_URL" \
        --skip-local-2fa \
        2>/dev/null || echo "Auth source may already exist"
    '';
  };

  # Generate API token for Homepage widget
  systemd.services.forgejo-homepage-token = {
    description = "Generate Forgejo API token for Homepage";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/forgejo-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0

      # Wait for Forgejo API
      for i in $(seq 1 60); do
        curl -sf http://127.0.0.1:80/api/v1/settings/api >/dev/null 2>&1 && break
        sleep 2
      done

      # Create a local bot user for API access
      podman exec -u git forgejo forgejo admin user create \
        --username homepage-bot \
        --password "homepage-bot-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --email homepage@lsck0.dev \
        --must-change-password=false 2>/dev/null || true

      # Generate token (skip if already exists)
      TOKEN=$(podman exec -u git forgejo forgejo admin user generate-access-token \
        --username homepage-bot \
        --token-name homepage \
        2>/dev/null | grep -oP 'Access token was successfully created\.\.\. \K.*' || true)

      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Forgejo Homepage token created"
      else
        echo "Token may already exist or creation failed"
      fi
    '';
  };

  # Generate runner registration token and save to NAS for runner VM
  systemd.services.forgejo-runner-token = {
    description = "Generate Forgejo runner registration token";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for Forgejo to be ready
      for i in $(seq 1 60); do
        podman exec -u git forgejo forgejo admin user list >/dev/null 2>&1 && break
        sleep 2
      done

      # Always regenerate token (they're one-use for registration)
      TOKEN=$(podman exec -u git forgejo forgejo actions generate-runner-token 2>/dev/null || true)
      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > /var/lib/homepage-tokens/forgejo-runner.token
        echo "Runner token generated"
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 2222 ];
}
