{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-105";

  # Resolve auth.internal directly to authentik VM
  networking.hosts."10.100.0.101" = [ "auth.internal" ];

  fileSystems = nasMount "/var/lib/forgejo" "forgejo"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo:7";
    ports = [ "80:3000" "2222:22" ];
    volumes = [ "/var/lib/forgejo:/data" ];
    environment = {
      FORGEJO__server__HTTP_PORT = "3000";
      FORGEJO__server__ROOT_URL = "https://git.internal/";
    };
  };

  # Configure OAuth2 auth source after Forgejo starts
  systemd.services.forgejo-oauth2-setup = {
    description = "Configure Forgejo OAuth2 with authentik";
    after = [ "podman-forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for Forgejo API
      for i in $(seq 1 60); do
        if curl -sf http://127.0.0.1:3000/api/v1/settings/api >/dev/null 2>&1; then break; fi
        sleep 2
      done

      # Check if auth source already exists
      SOURCES=$(curl -sf http://127.0.0.1:3000/api/v1/admin/identity-sources 2>/dev/null || echo "[]")
      if echo "$SOURCES" | jq -e '.[] | select(.name == "authentik")' >/dev/null 2>&1; then
        echo "OAuth2 source already exists"
        exit 0
      fi

      # Create via Forgejo CLI inside container
      podman exec forgejo forgejo admin auth add-oauth \
        --name authentik \
        --provider openidConnect \
        --key forgejo \
        --secret forgejo-oidc-secret-changeme \
        --auto-discover-url "http://auth.internal/application/o/forgejo-oidc/.well-known/openid-configuration" \
        --skip-local-2fa \
        --auto-create-user \
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
        curl -sf http://127.0.0.1:3000/api/v1/settings/api >/dev/null 2>&1 && break
        sleep 2
      done

      # Create a local bot user for API access
      podman exec forgejo forgejo admin user create \
        --username homepage-bot \
        --password "homepage-bot-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --email homepage@internal \
        --must-change-password=false 2>/dev/null || true

      # Generate access token
      TOKEN=$(podman exec forgejo forgejo admin user generate-access-token \
        --username homepage-bot \
        --token-name homepage \
        --scopes read 2>/dev/null | grep -oP 'Access token was successfully created\.\.\. \K.*' || true)

      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Forgejo Homepage token created"
      else
        echo "Token may already exist or creation failed"
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 2222 ];
}
