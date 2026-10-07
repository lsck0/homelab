{ config, lib, pkgs, nasMount, retry, inventory, site, catalog, lab, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  headscaleRoute = catalog.internal.headscale;
  headplaneRoute = catalog.internal.headplane;
  # the oidc clients instance.nix declares, as authelia registers them
  oidc = lib.listToAttrs (map (client: lib.nameValuePair client.id client) lab.oidc);
  autheliaIssuer = "https://${net.fqdn catalog.internal.authelia.host}";
  headscaleUrl = "https://${net.fqdn headscaleRoute.host}";
  # loopback, not the public name
  headscaleLocal = "http://127.0.0.1:${toString headscaleRoute.port}";
  headscaleDir = "/var/lib/headscale";
  headplaneDir = "/var/lib/headplane";
  # headscale caps an api key at 90 days; the daily job renews one with a week left
  apiKeyLifetime = "90d";
  apiKeyRenewWithinSeconds = 7 * 86400;

  # everything but the two secrets, which headplane 0.6 reads only inline; headplane-secret adds them with jq
  headplaneConfig = pkgs.writeText "headplane-config.json" (builtins.toJSON {
    server = { host = "0.0.0.0"; port = headplaneRoute.port; cookie_secure = true; };
    headscale = { url = headscaleLocal; public_url = headscaleUrl; config_strict = false; };
    integration.agent.enabled = false;
    oidc = {
      issuer = autheliaIssuer;
      client_id = oidc.headplane.id;
      client_secret_path = "${headplaneDir}/oidc-secret";
      token_endpoint_auth_method = oidc.headplane.tokenAuthMethod;
      redirect_uri = "https://${net.fqdn headplaneRoute.host}${oidc.headplane.callback}";
      disable_api_key_login = true;
    };
  });
in
{
  networking.hostName = "vm-138";

  homelab.nasMounts = nasMount headscaleDir "headscale";

  services.headscale = {
    enable = true;
    address = "0.0.0.0";
    port = headscaleRoute.port;
    settings = {
      server_url = headscaleUrl;
      dns = {
        base_domain = net.fqdn "vpn";
        nameservers.global = [ net.zones.internal.routerIp ];
      };
      prefixes = {
        v4 = net.tailnet;
        v6 = "fd7a:115c:a1e0::/48";
      };
      # device registration logs in through authelia
      oidc = {
        issuer = autheliaIssuer;
        client_id = oidc.headscale.id;
        client_secret_path = config.sops.secrets.headscale-oidc-secret.path;
        scope = [ "openid" "profile" "email" "groups" ];
        allowed_groups = [ "admins" "app-${oidc.headscale.id}" ];
        pkce.enabled = oidc.headscale.pkce;
        # vpn keeps running when authelia is down
        only_start_if_oidc_is_available = false;
      };
    };
  };
  sops.secrets.headscale-oidc-secret = { owner = "headscale"; };

  # Headplane, the web ui headscale does not ship; the tag for reading, the digest for what runs
  virtualisation.oci-containers.containers.headplane = {
    image = "ghcr.io/tale/headplane:0.6.0@sha256:b56ea59fd9424470bdb335f0be5524915fc4c34cc826ce25e583f440e4e56864";
    # host network: headscaleLocal must be the host's loopback
    extraOptions = [ "--network=host" ];
    volumes = [
      "${headplaneDir}:${headplaneDir}"
      # the only config source: HEADPLANE_* env is ignored without HEADPLANE_LOAD_ENV_OVERRIDES
      "${headplaneDir}/config.yaml:/etc/headplane/config.yaml:ro"
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
    path = [ pkgs.openssl pkgs.coreutils pkgs.jq ];
    startLimitIntervalSec = 0;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    # json is yaml; every file is private from its first byte and replaced whole
    script = ''
      set -euo pipefail
      umask 077
      install -d -m 0700 ${headplaneDir}
      # headplane needs a 32-char cookie secret, generated once
      [ -s ${headplaneDir}/cookie-secret ] || openssl rand -hex 16 > ${headplaneDir}/cookie-secret
      install -m 600 ${config.sops.secrets.headplane-oidc-secret.path} ${headplaneDir}/oidc-secret
      jq --rawfile cookie ${headplaneDir}/cookie-secret --rawfile key ${config.homelab.tokens.dir}/headplane-key.token \
        '.server.cookie_secret = ($cookie | rtrimstr("\n")) | .oidc.headscale_api_key = ($key | rtrimstr("\n"))' \
        ${headplaneConfig} > ${headplaneDir}/config.yaml.tmp
      mv ${headplaneDir}/config.yaml.tmp ${headplaneDir}/config.yaml
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
      set -euo pipefail
      umask 077
      ${retry} 60 2 curl -sf ${headscaleLocal}/health

      T=${config.homelab.tokens.ownDir}/headplane-key.token
      prefix=""
      if [ -s "$T" ]; then prefix=$(cut -d. -f1 "$T"); fi
      expires=$(headscale apikeys list -o json | jq -r --arg p "$prefix" '.[] | select(.prefix == $p) | .expiration.seconds')
      if [ -n "$prefix" ] && [ -n "$expires" ] && [ "$expires" -gt "$(( $(date +%s) + ${toString apiKeyRenewWithinSeconds} ))" ]; then
        echo "Headplane API key valid until $(date -d "@$expires")"
        exit 0
      fi
      key=$(headscale apikeys create --expiration ${apiKeyLifetime} | tail -1)
      # <prefix>.<secret>: anything else is an error message, never a key to install
      [[ "$key" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || { echo "headscale answered no api key" >&2; exit 1; }
      printf '%s' "$key" > "$T.tmp"
      mv "$T.tmp" "$T"
      echo "Headplane API key written to $T"
      # the superseded key stops working now, not when it expires
      if [ -n "$prefix" ]; then
        headscale apikeys expire --prefix "$prefix" || echo "could not expire the previous key $prefix" >&2
      fi
      # no-block: at boot headplane-secret waits on this unit
      systemctl --no-block try-restart headplane-secret.service podman-headplane.service
    '';
  };

  # headscale itself is reached by clients through the ingress, which relays their registration
  networking.firewall.allowedTCPPorts = [ headscaleRoute.port headplaneRoute.port ];
  homelab.ingressOnly.ports = [ headplaneRoute.port ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.headscale.sqlite = "${headscaleDir}/db.sqlite";
}
