{ config, pkgs, nasMount, ... }:
let
  ip = id: "http://10.100.0.${id}:80";

  # SSO gateway guarding the protected routes. Authelia (vm-128) replaced
  # Authentik: a single Go process in ~100 MB instead of Postgres + Redis +
  # server + worker at 4 GB. It serves both ForwardAuth (this middleware) and
  # OIDC (Nextcloud/Vaultwarden/Forgejo) at auth.lsck0.dev.
  sso = "authelia";
in {
  networking.hostName = "vm-100";

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-internal")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-internal");

  homelab.traefik = {
    enable = true;

    middlewares.authelia = {
      forwardAuth = {
        address = "http://10.100.0.128:9091/api/authz/forward-auth";
        trustForwardHeader = true;
        authResponseHeaders = [
          "Remote-User"
          "Remote-Groups"
          "Remote-Email"
          "Remote-Name"
        ];
      };
    };

    routers = {
      authelia-tls       = { rule = "Host(`auth.lsck0.dev`)";       service = "authelia";        entryPoints = [ "websecure" ]; };
      traefik-dash-tls   = { rule = "Host(`traefik.lsck0.dev`)";    service = "api@internal";    entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      homepage-tls       = { rule = "Host(`homepage.lsck0.dev`)";   service = "homepage";        entryPoints = [ "websecure" ]; };
      uptime-kuma-tls    = { rule = "Host(`status.lsck0.dev`)";     service = "uptime-kuma";     entryPoints = [ "websecure" ]; };
      forgejo-tls        = { rule = "Host(`git.lsck0.dev`)";        service = "forgejo";         entryPoints = [ "websecure" ]; };
      registry-tls       = { rule = "Host(`registry.lsck0.dev`)";   service = "registry-api";    entryPoints = [ "websecure" ]; };
      registry-ui-tls    = { rule = "Host(`registry-ui.lsck0.dev`)"; service = "registry-ui";    entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      taskchampion-tls   = { rule = "Host(`tasks.lsck0.dev`)";      service = "taskchampion";    entryPoints = [ "websecure" ]; };
      vaultwarden-tls    = { rule = "Host(`vault.lsck0.dev`)";      service = "vaultwarden";     entryPoints = [ "websecure" ]; };
      nextcloud-tls      = { rule = "Host(`cloud.lsck0.dev`)";      service = "nextcloud";       entryPoints = [ "websecure" ]; };
      qbittorrent-tls    = { rule = "Host(`torrent.lsck0.dev`)";    service = "qbittorrent";     entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      prowlarr-tls       = { rule = "Host(`prowlarr.lsck0.dev`)";   service = "prowlarr";        entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      sonarr-tls         = { rule = "Host(`sonarr.lsck0.dev`)";     service = "sonarr";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      radarr-tls         = { rule = "Host(`radarr.lsck0.dev`)";     service = "radarr";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      jellyfin-tls       = { rule = "Host(`jellyfin.lsck0.dev`)";   service = "jellyfin";        entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      audiobookshelf-tls = { rule = "Host(`abs.lsck0.dev`)";        service = "audiobookshelf";  entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      paperless-tls      = { rule = "Host(`paperless.lsck0.dev`)";  service = "paperless";       entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      paperless-ai-tls   = { rule = "Host(`paperless-ai.lsck0.dev`)"; service = "paperless-ai"; entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      hermes-tls         = { rule = "Host(`hermes.lsck0.dev`)";      service = "hermes";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      # No SSO: the TRMNL cloud polls this and cannot log in. The feed URLs
      # carry an unguessable token instead.
      calendar-tls       = { rule = "Host(`cal.lsck0.dev`)";         service = "calendar";        entryPoints = [ "websecure" ]; };
      wikijs-tls         = { rule = "Host(`wiki.lsck0.dev`)";       service = "wikijs";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      huginn-tls         = { rule = "Host(`huginn.lsck0.dev`)";     service = "huginn";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      homeassistant-tls  = { rule = "Host(`hass.lsck0.dev`)";       service = "homeassistant";   entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      grafana-tls        = { rule = "Host(`grafana.lsck0.dev`)";    service = "grafana";         entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      navidrome-tls      = { rule = "Host(`music.lsck0.dev`)";      service = "navidrome";       entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      kavita-tls         = { rule = "Host(`read.lsck0.dev`)";       service = "kavita";          entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      nas-tls            = { rule = "Host(`nas.lsck0.dev`)";        service = "nas";             entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      syncthing-tls      = { rule = "Host(`sync.lsck0.dev`)";       service = "syncthing";       entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      lldap-tls          = { rule = "Host(`lldap.lsck0.dev`)";      service = "lldap";           entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      # No SSO: nix clients authenticate to attic with their own token.
      attic-tls          = { rule = "Host(`attic.lsck0.dev`)";      service = "attic";           entryPoints = [ "websecure" ]; };
      proxmox-tls        = { rule = "Host(`proxmox.lsck0.dev`)";    service = "proxmox";         entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
    };

    services = {
      authelia.loadBalancer.servers        = [{ url = "http://10.100.0.128:9091"; }];
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
      paperless-ai.loadBalancer.servers     = [{ url = ip "125"; }];
      hermes.loadBalancer.servers           = [{ url = "http://10.100.0.126:11434"; }];
      calendar.loadBalancer.servers         = [{ url = ip "129"; }];
      wikijs.loadBalancer.servers           = [{ url = ip "116"; }];
      huginn.loadBalancer.servers           = [{ url = ip "114"; }];
      homeassistant.loadBalancer.servers    = [{ url = ip "115"; }];
      navidrome.loadBalancer.servers        = [{ url = ip "123"; }];
      kavita.loadBalancer.servers           = [{ url = ip "124"; }];
      nas.loadBalancer.servers              = [{ url = ip "105"; }];
      syncthing.loadBalancer.servers        = [{ url = "http://10.100.0.105:8384"; }];
      lldap.loadBalancer.servers            = [{ url = "http://10.100.0.133:17170"; }];
      attic.loadBalancer.servers            = [{ url = "http://10.100.0.131:8080"; }];
      proxmox.loadBalancer.servers          = [{ url = "https://192.168.178.200:8006"; }];
      proxmox.loadBalancer.serversTransport = "proxmox-transport";
    };

    serversTransports.proxmox-transport.insecureSkipVerify = true;
  };
}
