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
      "d /var/lib/traefik/certs 0700 traefik traefik -"
      "d /var/lib/crowdsec/config 0750 root root -"
      "d /var/lib/crowdsec/data 0750 root root -"
      "d /var/log/traefik 0750 root root -"
    ];

    environment.etc."traefik-certs-setup.sh" = {
      text = ''
        #!/bin/sh
        mkdir -p /var/lib/traefik/certs
        
        # Server certificate
        cat > /var/lib/traefik/certs/server-cert.pem << 'CERT_EOF'
        ${builtins.readFile ../../secrets/server-cert.pem}
        CERT_EOF
        
        # Server key
        cat > /var/lib/traefik/certs/server-key.pem << 'KEY_EOF'
        ${builtins.readFile ../../secrets/server-key.pem}
        KEY_EOF
        
        chown traefik:traefik /var/lib/traefik/certs/*.pem
        chmod 600 /var/lib/traefik/certs/server-key.pem
        chmod 644 /var/lib/traefik/certs/server-cert.pem
      '';
      mode = "0755";
    };

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
          storage = "/var/lib/traefik/acme/acme.json";
          dnsChallenge = {
            provider = "cloudflare";
            resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
          };
        };
        tls = {
          stores.default.defaultCertificate = {
            certFile = "/var/lib/traefik/certs/server-cert.pem";
            keyFile = "/var/lib/traefik/certs/server-key.pem";
          };
        };
      };
      dynamicConfigOptions = {
        http = { routers = cfg.routers; services = cfg.services; }
          // lib.optionalAttrs (cfg.middlewares != {}) { middlewares = cfg.middlewares; }
          // lib.optionalAttrs (cfg.serversTransports != {}) { serversTransports = cfg.serversTransports; };
      } // lib.optionalAttrs (cfg.tcp != {}) { tcp = cfg.tcp; };
    };

    systemd.services.traefik-certs = {
      description = "Setup certs for traefik";
      before = [ "traefik.service" ];
      wantedBy = [ "traefik.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "/etc/traefik-certs-setup.sh";
      };
    };

    networking.firewall.allowedTCPPorts = [ 80 443 8080 ];
  };
}
