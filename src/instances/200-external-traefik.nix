{ config, pkgs, ... }:
let
  externalCerts = pkgs.runCommand "external-local-certs" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout $out/key.pem -out $out/cert.pem \
      -days 3650 -subj "/CN=*.external.local" \
      -addext "subjectAltName=DNS:*.external.local,DNS:external.local"
  '';
in {
  networking.hostName = "vm-200";
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
      accessLog = {};
      api.dashboard = true;
      entryPoints = {
        web = { address = ":80"; http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; }; };
        websecure.address = ":443";
        # Non-HTTP services — add new entrypoints here for each service
        minecraft.address = ":25565";
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
        certFile = "${externalCerts}/cert.pem";
        keyFile = "${externalCerts}/key.pem";
      };
    };
    http = {
      middlewares.redirect-https = {
        redirectScheme = { scheme = "https"; permanent = true; };
      };

      routers = {
        # ── .external.local — HTTP (LAN) ──
        shlink       = { rule = "Host(`shlink.external.local`)";      service = "shlink";       entryPoints = [ "web" ]; };
        privatebin   = { rule = "Host(`paste.external.local`)";       service = "privatebin";   entryPoints = [ "web" ]; };
        share        = { rule = "Host(`share.external.local`)";       service = "share";        entryPoints = [ "web" ]; };
        headscale    = { rule = "Host(`hs.external.local`)";          service = "headscale";    entryPoints = [ "web" ]; };

        # ── .external.local — HTTPS (LAN, self-signed) ──
        shlink-local-tls     = { rule = "Host(`shlink.external.local`)";  service = "shlink";     entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
        privatebin-local-tls = { rule = "Host(`paste.external.local`)";   service = "privatebin"; entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
        share-local-tls      = { rule = "Host(`share.external.local`)";   service = "share";      entryPoints = [ "websecure" ]; tls = { options = "default"; }; };
        headscale-local-tls  = { rule = "Host(`hs.external.local`)";      service = "headscale";  entryPoints = [ "websecure" ]; tls = { options = "default"; }; };

        # ── lsck0.dev — HTTPS (internet) ──
        shlink-tls      = { rule = "Host(`shlink.lsck0.dev`)";      service = "shlink";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        privatebin-tls  = { rule = "Host(`paste.lsck0.dev`)";       service = "privatebin";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        share-tls       = { rule = "Host(`share.lsck0.dev`)";       service = "share";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        headscale-tls   = { rule = "Host(`hs.lsck0.dev`)";          service = "headscale";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      };

      services = {
        shlink.loadBalancer.servers       = [{ url = "http://10.200.0.201:80"; }];
        privatebin.loadBalancer.servers   = [{ url = "http://10.200.0.202:80"; }];
        share.loadBalancer.servers        = [{ url = "http://10.200.0.203:80"; }];
        headscale.loadBalancer.servers    = [{ url = "http://10.200.0.205:80"; }];
      };
    };
    # Non-HTTP services — TCP passthrough routing
    # mc.external.local:25565 → vm-204:25565 (Minecraft)
    tcp = {
      routers = {
        minecraft = {
          rule = "HostSNI(`*`)";
          service = "minecraft";
          entryPoints = [ "minecraft" ];
        };
      };
      services = {
        minecraft.loadBalancer.servers = [{ address = "10.200.0.204:25565"; }];
      };
    };
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 25565 ];
}
