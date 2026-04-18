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

  systemd.tmpfiles.rules = [
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
          authentik-local-tls      = { rule = "Host(`auth.internal.local`)";       service = "authentik";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          traefik-dash-local-tls   = { rule = "Host(`traefik.internal.local`)";    service = "api@internal";    entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          homepage-local-tls       = { rule = "Host(`home.internal.local`)";       service = "homepage";        entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          uptime-kuma-local-tls    = { rule = "Host(`status.internal.local`)";     service = "uptime-kuma";     entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          forgejo-local-tls        = { rule = "Host(`git.internal.local`)";        service = "forgejo";         entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          registry-local-tls       = { rule = "Host(`registry.internal.local`)";   service = "registry";        entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          taskchampion-local-tls   = { rule = "Host(`tasks.internal.local`)";      service = "taskchampion";    entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          vaultwarden-local-tls    = { rule = "Host(`vault.internal.local`)";      service = "vaultwarden";     entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          nextcloud-local-tls      = { rule = "Host(`cloud.internal.local`)";      service = "nextcloud";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
          qbittorrent-local-tls    = { rule = "Host(`torrent.internal.local`)";    service = "qbittorrent";     entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          prowlarr-local-tls       = { rule = "Host(`prowlarr.internal.local`)";   service = "prowlarr";        entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          sonarr-local-tls         = { rule = "Host(`sonarr.internal.local`)";     service = "sonarr";          entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          radarr-local-tls         = { rule = "Host(`radarr.internal.local`)";     service = "radarr";          entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          jellyfin-local-tls       = { rule = "Host(`jellyfin.internal.local`)";   service = "jellyfin";        entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          audiobookshelf-local-tls = { rule = "Host(`abs.internal.local`)";        service = "audiobookshelf";  entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          paperless-local-tls      = { rule = "Host(`paperless.internal.local`)";  service = "paperless";       entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          wikijs-local-tls         = { rule = "Host(`wiki.internal.local`)";       service = "wikijs";          entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          huginn-local-tls         = { rule = "Host(`huginn.internal.local`)";     service = "huginn";          entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          homeassistant-local-tls  = { rule = "Host(`hass.internal.local`)";       service = "homeassistant";   entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          grafana-local-tls        = { rule = "Host(`grafana.internal.local`)";    service = "grafana";         entryPoints = [ "websecure" ]; tls = { options = "default"; }; middlewares = [ "authentik" ]; };
          proxmox-local-tls        = { rule = "Host(`proxmox.internal.local`)";    service = "proxmox";         entryPoints = [ "websecure" ]; tls = { options = "default"; }; };

          # ── lsck0.dev — HTTPS (VPN / external) ──
          authentik-tls      = { rule = "Host(`auth.lsck0.dev`)";       service = "authentik";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          homepage-tls       = { rule = "Host(`home.lsck0.dev`)";       service = "homepage";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          uptime-kuma-tls    = { rule = "Host(`status.lsck0.dev`)";     service = "uptime-kuma";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          forgejo-tls        = { rule = "Host(`git.lsck0.dev`)";        service = "forgejo";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          registry-tls       = { rule = "Host(`registry.lsck0.dev`)";   service = "registry";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
          taskchampion-tls   = { rule = "Host(`tasks.lsck0.dev`)";      service = "taskchampion";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
          vaultwarden-tls    = { rule = "Host(`vault.lsck0.dev`)";      service = "vaultwarden";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; middlewares = [ "authentik" ]; };
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
        };

        services = {
          authentik.loadBalancer.servers      = [{ url = ip "101"; }];
          homepage.loadBalancer.servers       = [{ url = ip "102"; }];
          uptime-kuma.loadBalancer.servers    = [{ url = ip "103"; }];
          forgejo.loadBalancer.servers        = [{ url = ip "104"; }];
          registry.loadBalancer.servers       = [{ url = ip "107"; }];
          taskchampion.loadBalancer.servers   = [{ url = "http://10.100.0.108:8080"; }];
          vaultwarden.loadBalancer.servers    = [{ url = "http://10.100.0.109:8080"; }];
          nextcloud.loadBalancer.servers      = [{ url = ip "111"; }];
          qbittorrent.loadBalancer.servers    = [{ url = ip "112"; }];
          prowlarr.loadBalancer.servers       = [{ url = ip "113"; }];
          sonarr.loadBalancer.servers         = [{ url = ip "114"; }];
          radarr.loadBalancer.servers         = [{ url = ip "115"; }];
          jellyfin.loadBalancer.servers       = [{ url = ip "116"; }];
          audiobookshelf.loadBalancer.servers = [{ url = ip "117"; }];
          paperless.loadBalancer.servers      = [{ url = "http://10.100.0.118:8080"; }];
          wikijs.loadBalancer.servers         = [{ url = ip "119"; }];
          huginn.loadBalancer.servers         = [{ url = ip "120"; }];
          homeassistant.loadBalancer.servers  = [{ url = ip "121"; }];
          grafana.loadBalancer.servers        = [{ url = ip "122"; }];
          proxmox.loadBalancer.servers        = [{ url = "https://192.168.178.200:8006"; }];
          proxmox.loadBalancer.serversTransport = "proxmox-transport";
        };
        serversTransports.proxmox-transport.insecureSkipVerify = true;
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
