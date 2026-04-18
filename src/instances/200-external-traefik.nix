{ config, ... }: {
  networking.hostName = "vm-200";
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
      providers.file.filename = "/etc/traefik/dynamic.yaml";
    };
  };

  environment.etc."traefik/dynamic.yaml".text = builtins.toJSON {
    http = {
      middlewares.redirect-https = {
        redirectScheme = { scheme = "https"; permanent = true; };
      };

      routers = {
        # ── .external.local — HTTP (LAN) ──
        shlink       = { rule = "Host(`shlink.external.local`)";      service = "shlink";       entryPoints = [ "web" ]; };
        privatebin   = { rule = "Host(`paste.external.local`)";       service = "privatebin";   entryPoints = [ "web" ]; };
        share        = { rule = "Host(`share.external.local`)";       service = "share";        entryPoints = [ "web" ]; };

        # ── lsck0.dev — HTTPS (internet) ──
        shlink-tls      = { rule = "Host(`shlink.lsck0.dev`)";      service = "shlink";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        privatebin-tls  = { rule = "Host(`paste.lsck0.dev`)";       service = "privatebin";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
        share-tls       = { rule = "Host(`share.lsck0.dev`)";       service = "share";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      };

      services = {
        shlink.loadBalancer.servers       = [{ url = "http://10.200.0.201:80"; }];
        privatebin.loadBalancer.servers   = [{ url = "http://10.200.0.202:80"; }];
        share.loadBalancer.servers        = [{ url = "http://10.200.0.203:80"; }];
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

  networking.firewall.allowedTCPPorts = [ 80 443 25565 ];
}
