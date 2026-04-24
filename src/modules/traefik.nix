{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.traefik;
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

    crowdsecInstance = lib.mkOption {
      type = lib.types.str;
      description = "CrowdSec data directory name on NAS (e.g. crowdsec-internal).";
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
        api.insecure = true;
        entryPoints = {
          web = {
            address = ":80";
            http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; };
          };
          websecure.address = ":443";
        } // cfg.entryPoints;
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
          routers = cfg.routers;
          services = cfg.services;
          middlewares = cfg.middlewares;
          serversTransports = cfg.serversTransports;
        };
      } // lib.optionalAttrs (cfg.tcp != {}) { tcp = cfg.tcp; };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 8080 ];
  };
}
