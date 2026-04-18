{ config, pkgs, ... }:
let
  ip = id: "http://10.100.0.${id}:80";

  # Self-signed wildcard certificate for *.internal.local
  internalCerts = pkgs.runCommand "internal-local-certs" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $out/key.pem -out $out/cert.pem \
      -days 3650 -subj "/CN=*.internal.local" \
      -addext "subjectAltName=DNS:*.internal.local,DNS:internal.local"
  '';
in {
  networking.hostName = "vm-100";
  homelab.acmeEmail = "luca.sandrock@proton.me";

  sops.secrets.cloudflare-token = {};
  sops.templates."traefik.env".content = ''
    CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
  '';

  services.traefik = {
    environmentFiles = [ config.sops.templates."traefik.env".path ];
    enable = true;
    staticConfigOptions = {
      log.level = "DEBUG";
      entryPoints = {
        web = {
          address = ":80";
          http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; };
        };
        websecure.address = ":443";
      };
      certificatesResolvers.cloudflare.acme = {
        email = config.homelab.acmeEmail;
        storage = "/var/lib/traefik/acme.json";
        dnsChallenge = {
          provider = "cloudflare";
          resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
        };
      };
    };
    dynamicConfigOptions = {
      tls = {
        stores.default.defaultCertificate = {
          certFile = "${internalCerts}/cert.pem";
          keyFile = "${internalCerts}/key.pem";
        };
      };
      http = {
        middlewares.authentik = {
          forwardAuth = {
            address = "https://10.100.0.101:443/outpost.goauthentik.io/auth/traefik";
            tls = { insecureSkipVerify = true; };
            trustForwardHeader = true;
            authResponseHeaders = [
              "X-authentik-username"
              "X-authentik-groups"
              "X-authentik-email"
              "X-authentik-name"
              "X-authentik-uid"
            ];
          };
        };

        routers = {
          # ── .internal.local — HTTPS (LAN, self-signed) ──
          authentik-local-tls      = { rule = "Host(`auth.internal.local`)";      service = "authentik";      entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          uptime-kuma-local-tls    = { rule = "Host(`status.internal.local`)";    service = "uptime-kuma";    entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          forgejo-local-tls        = { rule = "Host(`git.internal.local`)";       service = "forgejo";        entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          registry-local-tls       = { rule = "Host(`registry.internal.local`)";  service = "registry";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          homepage-local-tls       = { rule = "Host(`home.internal.local`)";      service = "homepage";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          vaultwarden-local-tls    = { rule = "Host(`vault.internal.local`)";     service = "vaultwarden";    entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          taskchampion-local-tls   = { rule = "Host(`tasks.internal.local`)";     service = "taskchampion";   entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          nextcloud-local-tls      = { rule = "Host(`cloud.internal.local`)";     service = "nextcloud";      entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          paperless-local-tls      = { rule = "Host(`paperless.internal.local`)"; service = "paperless";      entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          jellyfin-local-tls       = { rule = "Host(`jellyfin.internal.local`)";  service = "jellyfin";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          huginn-local-tls         = { rule = "Host(`huginn.internal.local`)";    service = "huginn";         entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          homeassistant-local-tls  = { rule = "Host(`hass.internal.local`)";      service = "homeassistant";  entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };

          # ── lsck0.dev — HTTPS (VPN / external) ──
          authentik-tls      = { rule = "Host(`auth.lsck0.dev`)";      service = "authentik";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          uptime-kuma-tls    = { rule = "Host(`status.lsck0.dev`)";    service = "uptime-kuma";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          forgejo-tls        = { rule = "Host(`git.lsck0.dev`)";       service = "forgejo";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          registry-tls       = { rule = "Host(`registry.lsck0.dev`)";  service = "registry";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          homepage-tls       = { rule = "Host(`home.lsck0.dev`)";      service = "homepage";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          vaultwarden-tls    = { rule = "Host(`vault.lsck0.dev`)";     service = "vaultwarden";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          taskchampion-tls   = { rule = "Host(`tasks.lsck0.dev`)";     service = "taskchampion";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          nextcloud-tls      = { rule = "Host(`cloud.lsck0.dev`)";     service = "nextcloud";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          paperless-tls      = { rule = "Host(`paperless.lsck0.dev`)"; service = "paperless";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          jellyfin-tls       = { rule = "Host(`jellyfin.lsck0.dev`)";  service = "jellyfin";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          huginn-tls         = { rule = "Host(`huginn.lsck0.dev`)";    service = "huginn";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          homeassistant-tls  = { rule = "Host(`hass.lsck0.dev`)";      service = "homeassistant";  entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        };

        services = {
          authentik.loadBalancer.servers     = [{ url = ip "101"; }];
          uptime-kuma.loadBalancer.servers   = [{ url = ip "102"; }];
          forgejo.loadBalancer.servers       = [{ url = ip "103"; }];
          registry.loadBalancer.servers      = [{ url = ip "106"; }];
          homepage.loadBalancer.servers      = [{ url = ip "108"; }];
          vaultwarden.loadBalancer.servers   = [{ url = "http://10.100.0.109:8080"; }];
          taskchampion.loadBalancer.servers  = [{ url = "http://10.100.0.110:8080"; }];
          nextcloud.loadBalancer.servers     = [{ url = ip "111"; }];
          paperless.loadBalancer.servers     = [{ url = "http://10.100.0.112:8080"; }];
          jellyfin.loadBalancer.servers      = [{ url = ip "113"; }];
          huginn.loadBalancer.servers        = [{ url = ip "114"; }];
          homeassistant.loadBalancer.servers = [{ url = ip "115"; }];
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
