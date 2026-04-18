{ config, ... }:
let
  ip = id: "http://10.100.0.${id}:80";
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
      entryPoints = {
        web.address = ":80";
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
      providers.file.filename = "/etc/traefik/dynamic.yaml";
    };
  };

  environment.etc."traefik/dynamic.yaml".text = builtins.toJSON {
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
        # ── .internal.local — HTTP (LAN) ──
        authentik      = { rule = "Host(`auth.internal.local`)";      service = "authentik";      entryPoints = [ "web" ]; };
        uptime-kuma    = { rule = "Host(`status.internal.local`)";    service = "uptime-kuma";    entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        forgejo        = { rule = "Host(`git.internal.local`)";       service = "forgejo";        entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        registry       = { rule = "Host(`registry.internal.local`)";  service = "registry";       entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        homepage       = { rule = "Host(`home.internal.local`)";      service = "homepage";       entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        vaultwarden    = { rule = "Host(`vault.internal.local`)";     service = "vaultwarden";    entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        taskchampion   = { rule = "Host(`tasks.internal.local`)";     service = "taskchampion";   entryPoints = [ "web" ]; };
        nextcloud      = { rule = "Host(`cloud.internal.local`)";     service = "nextcloud";      entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        paperless      = { rule = "Host(`paperless.internal.local`)"; service = "paperless";      entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        jellyfin       = { rule = "Host(`jellyfin.internal.local`)";  service = "jellyfin";       entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        huginn         = { rule = "Host(`huginn.internal.local`)";    service = "huginn";         entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };
        homeassistant  = { rule = "Host(`hass.internal.local`)";      service = "homeassistant";  entryPoints = [ "web" ]; middlewares = [ "authentik" ]; };

        # ── lsck0.dev — HTTPS (VPN / external) ──
        authentik-tls      = { rule = "Host(`auth.lsck0.dev`)";      service = "authentik";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        uptime-kuma-tls    = { rule = "Host(`status.lsck0.dev`)";    service = "uptime-kuma";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        forgejo-tls        = { rule = "Host(`git.lsck0.dev`)";       service = "forgejo";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        registry-tls       = { rule = "Host(`registry.lsck0.dev`)";  service = "registry";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        homepage-tls       = { rule = "Host(`home.lsck0.dev`)";      service = "homepage";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        vaultwarden-tls    = { rule = "Host(`vault.lsck0.dev`)";     service = "vaultwarden";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        taskchampion-tls   = { rule = "Host(`tasks.lsck0.dev`)";     service = "taskchampion";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        nextcloud-tls      = { rule = "Host(`cloud.lsck0.dev`)";     service = "nextcloud";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
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
        vaultwarden.loadBalancer.servers   = [{ url = ip "109"; }];
        taskchampion.loadBalancer.servers  = [{ url = ip "110"; }];
        nextcloud.loadBalancer.servers     = [{ url = ip "111"; }];
        paperless.loadBalancer.servers     = [{ url = ip "112"; }];
        jellyfin.loadBalancer.servers      = [{ url = ip "113"; }];
        huginn.loadBalancer.servers        = [{ url = ip "114"; }];
        homeassistant.loadBalancer.servers = [{ url = ip "115"; }];
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
