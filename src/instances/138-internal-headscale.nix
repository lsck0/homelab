{ config, pkgs, nasMount, retry, ... }:
let
  # loopback, not the public hs.lsck0.dev
  headscaleLocal = "http://127.0.0.1:80";
in
{
  # internal, not the dmz
  networking.hostName = "vm-138";

  fileSystems = nasMount "/var/lib/headscale" "headscale"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = 80;
    settings = {
      server_url = "https://hs.lsck0.dev";
      dns = {
        base_domain = "vpn.lsck0.dev";
        nameservers.global = [ "10.100.0.1" ];
      };
      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };
      # device registration logs in through authelia
      oidc = {
        issuer = "https://auth.lsck0.dev";
        client_id = "headscale";
        client_secret_path = config.sops.secrets.headscale-oidc-secret.path;
        scope = [ "openid" "profile" "email" "groups" ];
        allowed_groups = [ "admins" "app-headscale" ];
        pkce.enabled = true;
        # vpn keeps running when authelia is down
        only_start_if_oidc_is_available = false;
      };
    };
  };
  sops.secrets.headscale-oidc-secret = { owner = "headscale"; };

  # ── Headplane ──────────────────────────────────────────────────────────────
  # the web ui headscale does not ship
  virtualisation.oci-containers.containers.headplane = {
    image = "ghcr.io/tale/headplane:0.6.0";
    # host network: headscaleLocal must be the host's loopback
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/headplane:/var/lib/headplane"
      # headplane 0.6.0 needs this file to start
      "/var/lib/headplane/config.yaml:/etc/headplane/config.yaml:ro"
    ];
    environment = {
      HEADPLANE_SERVER__HOST = "0.0.0.0";
      HEADPLANE_SERVER__PORT = "3000";
      HEADPLANE_SERVER__COOKIE_SECURE = "true";
      HEADPLANE_HEADSCALE__URL = headscaleLocal;
      HEADPLANE_HEADSCALE__PUBLIC_URL = "https://hs.lsck0.dev";
      # no headscale config file is mounted
      HEADPLANE_HEADSCALE__CONFIG_STRICT = "false";
    };
    environmentFiles = [ "/var/lib/headplane/cookie.env" ];
  };

  # headplane needs a 32-char cookie secret
  sops.secrets.headplane-oidc-secret = {};
  systemd.services.headplane-secret = {
    description = "Generate the Headplane cookie secret";
    before = [ "podman-headplane.service" ];
    requiredBy = [ "podman-headplane.service" ];
    # oidc sessions act through this key
    after = [ "headplane-apikey.service" ];
    requires = [ "headplane-apikey.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      mkdir -p /var/lib/headplane
      if [ ! -s /var/lib/headplane/cookie.env ]; then
        printf 'HEADPLANE_SERVER__COOKIE_SECRET=%s\n' \
          "$(openssl rand -hex 16)" > /var/lib/headplane/cookie.env
        chmod 600 /var/lib/headplane/cookie.env
      fi
      secret=$(cut -d= -f2 /var/lib/headplane/cookie.env)
      install -m 600 ${config.sops.secrets.headplane-oidc-secret.path} /var/lib/headplane/oidc-secret
      apikey=$(cat /var/lib/homepage-tokens/headplane-key.token)

      # settings rewritten every run, secret generated once
      cat > /var/lib/headplane/config.yaml <<EOF
      server:
        host: "0.0.0.0"
        port: 3000
        cookie_secret: "$secret"
        cookie_secure: true
      headscale:
        url: "${headscaleLocal}"
        public_url: "https://hs.lsck0.dev"
        config_strict: false
      integration:
        agent:
          enabled: false
      oidc:
        issuer: "https://auth.lsck0.dev"
        client_id: "headplane"
        client_secret_path: "/var/lib/headplane/oidc-secret"
        token_endpoint_auth_method: "client_secret_post"
        redirect_uri: "https://hs-ui.lsck0.dev/admin/oidc/callback"
        disable_api_key_login: true
        headscale_api_key: "$apikey"
      EOF
      # strip the heredoc indentation
      sed -i 's/^      //' /var/lib/headplane/config.yaml
      chmod 600 /var/lib/headplane/config.yaml
    '';
  };

  # headplane sign-in takes a headscale api key
  systemd.services.headplane-apikey = {
    description = "Generate a Headscale API key for Headplane";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.headscale pkgs.curl pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 60; };
    script = ''
      ${retry} 60 2 curl -sf ${headscaleLocal}/health

      T=/var/lib/homepage-tokens/headplane-key.token
      if [ -s "$T" ]; then
        echo "Headplane API key already present"
        exit 0
      fi
      # 90d is headscale's max; reminted after expiry
      headscale apikeys create --expiration 90d | tail -1 | tr -d '\n' > "$T"
      chmod 600 "$T"
      echo "Headplane API key written to $T"
    '';
  };

  # 80 headscale (relayed for client registration)
  networking.firewall.allowedTCPPorts = [ 80 3000 ];
  homelab.ingressOnly.ports = [ 3000 ];
}
