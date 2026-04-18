{ pkgs, ... }: {
  networking.hostName = "vm-104";

  # Resolve auth.internal.home directly to authentik VM
  networking.hosts."10.100.0.101" = [ "auth.internal.home" ];

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo:7";
    ports = [ "80:3000" "2222:22" ];
    volumes = [ "/var/lib/forgejo:/data" ];
    environment = {
      FORGEJO__server__HTTP_PORT = "3000";
      FORGEJO__server__ROOT_URL = "https://git.internal.home/";
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
        --auto-discover-url "http://auth.internal.home/application/o/forgejo-oidc/.well-known/openid-configuration" \
        --skip-local-2fa \
        --auto-create-user \
        2>/dev/null || echo "Auth source may already exist"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 2222 ];
}
