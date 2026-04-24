{ config, pkgs, nasMount, ... }:
{
  networking.hostName = "vm-200";

  fileSystems = nasMount "/var/lib/crowdsec" "crowdsec-external";

  homelab.traefik = {
    enable = true;

    entryPoints.minecraft.address = ":25565";

    routers = {
      traefik-dash-tls = { rule = "Host(`ext-traefik.lsck0.dev`)"; service = "api@internal"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      headscale-tls    = { rule = "Host(`hs.lsck0.dev`)";          service = "headscale";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      searxng-tls      = { rule = "Host(`search.lsck0.dev`)";      service = "searxng";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      shlink-tls       = { rule = "Host(`shlink.lsck0.dev`)";      service = "shlink";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      privatebin-tls   = { rule = "Host(`paste.lsck0.dev`)";       service = "privatebin";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      share-tls        = { rule = "Host(`share.lsck0.dev`)";       service = "share";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      hello-tls        = { rule = "Host(`hello.lsck0.dev`)";       service = "hello";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
    };

    services = {
      headscale.loadBalancer.servers    = [{ url = "http://10.200.0.201:80"; }];
      searxng.loadBalancer.servers      = [{ url = "http://10.200.0.202:80"; }];
      shlink.loadBalancer.servers       = [{ url = "http://10.200.0.203:80"; }];
      privatebin.loadBalancer.servers   = [{ url = "http://10.200.0.204:80"; }];
      share.loadBalancer.servers        = [{ url = "http://10.200.0.205:80"; }];
      hello.loadBalancer.servers        = [{ url = "http://10.200.0.208:80"; }];
    };

    tcp = {
      routers.minecraft = {
        rule = "HostSNI(`*`)";
        service = "minecraft";
        entryPoints = [ "minecraft" ];
      };
      services.minecraft.loadBalancer.servers = [{ address = "10.200.0.207:25565"; }];
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
