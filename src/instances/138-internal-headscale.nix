{ config, pkgs, nasMount, retry, ... }:
let
  # Headplane talks to Headscale over the loopback address rather than hs.lsck0.dev: the public
  headscaleLocal = "http://127.0.0.1:80";
in
{
  # Internal, not the DMZ.
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
    };
  };

  # ── Headplane ──────────────────────────────────────────────────────────────
  # The web UI Headscale does not ship.
  virtualisation.oci-containers.containers.headplane = {
    image = "ghcr.io/tale/headplane:0.6.0";
    ports = [ "3000:3000" ];
    volumes = [
      "/var/lib/headplane:/var/lib/headplane"
      # Headplane 0.6.0 will not start without this file
      "/var/lib/headplane/config.yaml:/etc/headplane/config.yaml:ro"
    ];
    environment = {
      HEADPLANE_SERVER__HOST = "0.0.0.0";
      HEADPLANE_SERVER__PORT = "3000";
      HEADPLANE_SERVER__COOKIE_SECURE = "true";
      HEADPLANE_HEADSCALE__URL = headscaleLocal;
      HEADPLANE_HEADSCALE__PUBLIC_URL = "https://hs.lsck0.dev";
      # No config file is mounted.
      HEADPLANE_HEADSCALE__CONFIG_STRICT = "false";
    };
    environmentFiles = [ "/var/lib/headplane/cookie.env" ];
  };

  # Headplane refuses to start without a 32-character cookie secret, and it signs sessions
  systemd.services.headplane-secret = {
    description = "Generate the Headplane cookie secret";
    before = [ "podman-headplane.service" ];
    requiredBy = [ "podman-headplane.service" ];
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

      # Written every run so the settings stay in this repo, but the secret is
      # only generated once above.
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
      EOF
      # the heredoc above is indented for readability; strip it back out.
      sed -i 's/^      //' /var/lib/headplane/config.yaml
      chmod 600 /var/lib/headplane/config.yaml
    '';
  };

  # Signing in to Headplane means pasting a Headscale API key.
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
      # 90d is headscale's own default and the longest it offers; the unit
      # will mint a new one once this expires and the file is removed.
      headscale apikeys create --expiration 90d | tail -1 | tr -d '\n' > "$T"
      chmod 600 "$T"
      echo "Headplane API key written to $T"
    '';
  };

  # 80 Headscale (relayed in for client registration)
  networking.firewall.allowedTCPPorts = [ 80 3000 ];
}
