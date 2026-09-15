{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.traefik;

  # Baseline response-header hardening attached to every websecure route: HSTS,
  # no MIME sniffing, deny framing, a referrer policy. Individual routers can
  # opt out by listing themselves in cfg.noSecureHeaders (e.g. an app that must
  # be embedded in a frame).
  secureHeadersMiddleware = {
    secure-headers.headers = {
      stsSeconds = 31536000;
      stsIncludeSubdomains = true;
      stsPreload = true;
      contentTypeNosniff = true;
      browserXssFilter = true;
      frameDeny = true;
      referrerPolicy = "strict-origin-when-cross-origin";
    };
  };

  # Ensure every websecure route has tls.certResolver = "cloudflare" unless
  # overridden, and prepend the secure-headers middleware unless opted out.
  routersWithTls = lib.mapAttrs (name: router:
    let
      eps = router.entryPoints or [];
      needsTls = builtins.elem "websecure" eps;
      hasCertResolver = (router ? tls) && (router.tls ? certResolver);
      withTls =
        if needsTls && !hasCertResolver then
          router // { tls = (router.tls or {}) // { certResolver = "cloudflare"; }; }
        else
          router;
      wantsHeaders = needsTls && !(builtins.elem name cfg.noSecureHeaders);
    in
    if wantsHeaders then
      withTls // { middlewares = [ "secure-headers" ] ++ (withTls.middlewares or []); }
    else
      withTls
  ) cfg.routers;
in {
  options.homelab.traefik = {
    enable = lib.mkEnableOption "Traefik reverse proxy with ACME and CrowdSec";

    entryPoints = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional entryPoints beyond web/websecure.";
    };

    routers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP routers.";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP services.";
    };

    tcp = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik TCP config (routers + services).";
    };

    middlewares = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP middlewares.";
    };

    serversTransports = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik servers transports.";
    };

    noSecureHeaders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Router names that should NOT get the secure-headers middleware.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "WARN";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare-token = {};
    sops.templates."traefik.env".content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
    '';

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
      "d /var/lib/traefik 0700 traefik traefik -"
      "d /var/lib/traefik/acme 0700 traefik traefik -"
      "d /var/lib/crowdsec/config 0750 root root -"
      "d /var/lib/crowdsec/data 0750 root root -"
      "d /var/log/traefik 0750 root root -"
    ];

    services.traefik = {
      enable = true;
      environmentFiles = [ config.sops.templates."traefik.env".path ];
      staticConfigOptions = {
        log.level = cfg.logLevel;
        accessLog = {};
        api.dashboard = true;
        entryPoints = {
          web = {
            address = ":80";
            http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; };
          };
          websecure.address = ":443";
        } // cfg.entryPoints;
        certificatesResolvers.cloudflare.acme = {
          email = config.homelab.acmeEmail;
          storage = "/var/lib/traefik/acme/acme.json";
          dnsChallenge = {
            provider = "cloudflare";
            resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
          };
        };
      };
      dynamicConfigOptions = {
        http = {
          routers = routersWithTls;
          services = cfg.services;
          middlewares = cfg.middlewares // secureHeadersMiddleware;
        }
          // lib.optionalAttrs (cfg.serversTransports != {}) { serversTransports = cfg.serversTransports; };
      } // lib.optionalAttrs (cfg.tcp != {}) { tcp = cfg.tcp; };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];
  };
}
