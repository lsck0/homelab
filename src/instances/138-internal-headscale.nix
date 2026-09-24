{ config, pkgs, nasMount, retry, ... }:
let
  # Headplane talks to Headscale over the loopback address rather than
  # hs.lsck0.dev: the public name resolves to the external Traefik, so a
  # request from this VM would leave the house and come back in.
  headscaleLocal = "http://127.0.0.1:80";
in
{
  # Internal, not the DMZ. Headscale has to be reachable from the internet for
  # a client to register, but it is the trust anchor of the mesh - the thing
  # that decides which machines are on the network - and that does not belong
  # on the same side as the services deliberately exposed to strangers. It is
  # relayed in by the external Traefik like any other internal host, with
  # auth = "own" so ForwardAuth does not sit in front of a protocol that
  # cannot log in to Authelia.
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
  # The web UI Headscale does not ship. Users, nodes and pre-auth keys through
  # a browser instead of `headscale` subcommands over ssh.
  virtualisation.oci-containers.containers.headplane = {
    image = "ghcr.io/tale/headplane:0.6.0";
    ports = [ "3000:3000" ];
    volumes = [
      "/var/lib/headplane:/var/lib/headplane"
    ];
    environment = {
      HEADPLANE_SERVER__HOST = "0.0.0.0";
      HEADPLANE_SERVER__PORT = "3000";
      HEADPLANE_SERVER__COOKIE_SECURE = "true";
      HEADPLANE_HEADSCALE__URL = headscaleLocal;
      HEADPLANE_HEADSCALE__PUBLIC_URL = "https://hs.lsck0.dev";
      # No config file is mounted. The NixOS headscale module renders its
      # config into the store, not into /var/lib/headscale, so the bind mount
      # this used to carry pointed at nothing and podman refused to start the
      # container at all: "statfs /var/lib/headscale/config.yaml: no such file
      # or directory". Headplane only reads it to display DNS and prefix
      # settings, and works from the API alone with strict mode off.
      HEADPLANE_HEADSCALE__CONFIG_STRICT = "false";
    };
    environmentFiles = [ "/var/lib/headplane/cookie.env" ];
  };

  # Headplane refuses to start without a 32-character cookie secret, and it
  # signs sessions, so it is generated here and kept rather than baked into
  # the nix store where it would be world-readable.
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
    '';
  };

  # Signing in to Headplane means pasting a Headscale API key. Generating one
  # here and leaving it with the other tokens beats asking someone to ssh in
  # and run `headscale apikeys create` before they can use the UI.
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

  # 80 Headscale (relayed in for client registration), 3000 Headplane
  # (Authelia in front, admins only).
  networking.firewall.allowedTCPPorts = [ 80 3000 ];
}
