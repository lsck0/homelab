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

  # Headplane
  # the web ui headscale does not ship
  virtualisation.oci-containers.containers.headplane = {
    image = "ghcr.io/tale/headplane:0.6.0";
    # host network: headscaleLocal must be the host's loopback
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/headplane:/var/lib/headplane"
      # the only config source: HEADPLANE_* env is ignored without HEADPLANE_LOAD_ENV_OVERRIDES
      "/var/lib/headplane/config.yaml:/etc/headplane/config.yaml:ro"
    ];
  };

  sops.secrets.headplane-oidc-secret = {};
  systemd.services.headplane-secret = {
    description = "Generate the Headplane cookie secret and config";
    before = [ "podman-headplane.service" ];
    wantedBy = [ "podman-headplane.service" ];
    # oidc sessions act through this key
    after = [ "headplane-apikey.service" ];
    wants = [ "headplane-apikey.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    startLimitIntervalSec = 0;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      mkdir -p /var/lib/headplane
      # headplane needs a 32-char cookie secret
      [ -s /var/lib/headplane/cookie-secret ] || (umask 077; openssl rand -hex 16 > /var/lib/headplane/cookie-secret)
      secret=$(cat /var/lib/headplane/cookie-secret)
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
      chmod 600 /var/lib/headplane/config.yaml
    '';
  };

  # headplane sign-in takes a headscale api key; daily, so a long uptime cannot outlive it
  systemd.services.headplane-apikey = {
    description = "Generate a Headscale API key for Headplane";
    after = [ "headscale.service" ];
    wants = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];
    startAt = "daily";
    path = [ pkgs.headscale pkgs.curl pkgs.coreutils pkgs.jq pkgs.systemd ];
    startLimitIntervalSec = 0;
    serviceConfig = { Type = "oneshot"; Restart = "on-failure"; RestartSec = 60; };
    script = ''
      ${retry} 60 2 curl -sf ${headscaleLocal}/health

      T=/var/lib/homepage-tokens/headplane-key.token
      prefix=$(cut -d. -f1 "$T" 2>/dev/null || true)
      expires=$(headscale apikeys list -o json | jq -r --arg p "$prefix" '.[] | select(.prefix == $p) | .expiration.seconds')
      if [ -n "$prefix" ] && [ -n "$expires" ] && [ "$expires" -gt "$(( $(date +%s) + 7 * 86400 ))" ]; then
        echo "Headplane API key valid until $(date -d "@$expires")"
        exit 0
      fi
      # 90d is headscale's max
      headscale apikeys create --expiration 90d | tail -1 | tr -d '\n' > "$T.tmp"
      chmod 600 "$T.tmp"
      mv "$T.tmp" "$T"
      echo "Headplane API key written to $T"
      # no-block: at boot headplane-secret waits on this unit
      systemctl --no-block try-restart headplane-secret.service podman-headplane.service
    '';
  };

  # 80 headscale (relayed for client registration)
  networking.firewall.allowedTCPPorts = [ 80 3000 ];
  homelab.ingressOnly.ports = [ 3000 ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.headscale.sqlite = "/var/lib/headscale/db.sqlite";
}
