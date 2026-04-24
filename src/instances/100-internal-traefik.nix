{ config, pkgs, nasMount, ... }:
let
  ip = id: "http://10.100.0.${id}:80";
in {
  networking.hostName = "vm-100";
  homelab.acmeEmail = "luca.sandrock@proton.me";

  sops.secrets.cloudflare-token = {};
  sops.templates."traefik.env".content = ''
    CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
  '';

  # ── CrowdSec ──────────────────────────────────────────────
  virtualisation.oci-containers.containers.crowdsec = {
    image = "crowdsecurity/crowdsec:latest";
    volumes = [
      "/var/lib/crowdsec/config:/etc/crowdsec"
      "/var/lib/crowdsec/data:/var/lib/crowdsec/data"
      "/var/log/traefik:/var/log/traefik:ro"
    ];
    ports = [ "127.0.0.1:8180:8080" ];
    environment = {
      COLLECTIONS = "crowdsecurity/traefik crowdsecurity/http-cve";
    };
  };

  fileSystems = nasMount "/var/lib/crowdsec" "crowdsec-internal";

  systemd.tmpfiles.rules = [
    "d /var/lib/traefik 0700 traefik traefik -"
    "d /var/lib/crowdsec/config 0750 root root -"
    "d /var/lib/crowdsec/data 0750 root root -"
    "d /var/log/traefik 0750 root root -"
  ];

  services.traefik = {
    environmentFiles = [ config.sops.templates."traefik.env".path ];
    enable = true;
    staticConfigOptions = {
      log.level = "WARN";
      accessLog = {};
      api.dashboard = true;
      api.insecure = true;
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
          authentik-tls      = { rule = "Host(`auth.lsck0.dev`)";       service = "authentik";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          traefik-dash-tls   = { rule = "Host(`traefik.lsck0.dev`)";    service = "api@internal";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          homepage-tls       = { rule = "Host(`homepage.lsck0.dev`)";   service = "homepage";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          uptime-kuma-tls    = { rule = "Host(`status.lsck0.dev`)";     service = "uptime-kuma";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          forgejo-tls        = { rule = "Host(`git.lsck0.dev`)";        service = "forgejo";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          registry-tls       = { rule = "Host(`registry.lsck0.dev`)";   service = "registry-api";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          registry-ui-tls    = { rule = "Host(`registry-ui.lsck0.dev`)"; service = "registry-ui";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          taskchampion-tls   = { rule = "Host(`tasks.lsck0.dev`)";      service = "taskchampion";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          vaultwarden-tls    = { rule = "Host(`vault.lsck0.dev`)";      service = "vaultwarden";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          nextcloud-tls      = { rule = "Host(`cloud.lsck0.dev`)";      service = "nextcloud";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          qbittorrent-tls    = { rule = "Host(`torrent.lsck0.dev`)";    service = "qbittorrent";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          prowlarr-tls       = { rule = "Host(`prowlarr.lsck0.dev`)";   service = "prowlarr";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          sonarr-tls         = { rule = "Host(`sonarr.lsck0.dev`)";     service = "sonarr";          entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          radarr-tls         = { rule = "Host(`radarr.lsck0.dev`)";     service = "radarr";          entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          jellyfin-tls       = { rule = "Host(`jellyfin.lsck0.dev`)";   service = "jellyfin";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          audiobookshelf-tls = { rule = "Host(`abs.lsck0.dev`)";        service = "audiobookshelf";  entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          paperless-tls      = { rule = "Host(`paperless.lsck0.dev`)";  service = "paperless";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          wikijs-tls         = { rule = "Host(`wiki.lsck0.dev`)";       service = "wikijs";          entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          huginn-tls         = { rule = "Host(`huginn.lsck0.dev`)";     service = "huginn";          entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          homeassistant-tls  = { rule = "Host(`hass.lsck0.dev`)";       service = "homeassistant";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          grafana-tls        = { rule = "Host(`grafana.lsck0.dev`)";    service = "grafana";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          navidrome-tls      = { rule = "Host(`music.lsck0.dev`)";      service = "navidrome";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          kavita-tls         = { rule = "Host(`read.lsck0.dev`)";       service = "kavita";          entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          nas-tls            = { rule = "Host(`nas.lsck0.dev`)";        service = "nas";             entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          proxmox-tls        = { rule = "Host(`proxmox.lsck0.dev`)";    service = "proxmox";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
        };

        services = {
          authentik.loadBalancer.servers       = [{ url = ip "101"; }];
          homepage.loadBalancer.servers        = [{ url = ip "102"; }];
          uptime-kuma.loadBalancer.servers      = [{ url = ip "104"; }];
          grafana.loadBalancer.servers          = [{ url = ip "103"; }];
          forgejo.loadBalancer.servers          = [{ url = ip "107"; }];
          registry-api.loadBalancer.servers     = [{ url = "http://10.100.0.109:5000"; }];
          registry-ui.loadBalancer.servers      = [{ url = ip "109"; }];
          taskchampion.loadBalancer.servers     = [{ url = "http://10.100.0.110:8080"; }];
          vaultwarden.loadBalancer.servers      = [{ url = "http://10.100.0.111:8080"; }];
          nextcloud.loadBalancer.servers        = [{ url = ip "112"; }];
          qbittorrent.loadBalancer.servers      = [{ url = ip "117"; }];
          prowlarr.loadBalancer.servers         = [{ url = ip "118"; }];
          sonarr.loadBalancer.servers           = [{ url = ip "120"; }];
          radarr.loadBalancer.servers           = [{ url = ip "119"; }];
          jellyfin.loadBalancer.servers         = [{ url = ip "121"; }];
          audiobookshelf.loadBalancer.servers   = [{ url = ip "122"; }];
          paperless.loadBalancer.servers        = [{ url = "http://10.100.0.113:8080"; }];
          wikijs.loadBalancer.servers           = [{ url = ip "116"; }];
          huginn.loadBalancer.servers           = [{ url = ip "114"; }];
          homeassistant.loadBalancer.servers    = [{ url = ip "115"; }];
          navidrome.loadBalancer.servers        = [{ url = ip "123"; }];
          kavita.loadBalancer.servers           = [{ url = ip "124"; }];
          nas.loadBalancer.servers              = [{ url = ip "105"; }];
          proxmox.loadBalancer.servers          = [{ url = "https://192.168.178.200:8006"; }];
          proxmox.loadBalancer.serversTransport = "proxmox-transport";
        };
        serversTransports.proxmox-transport.insecureSkipVerify = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 8080 ];
}
