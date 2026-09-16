{ config, lib, pkgs, nasMount, ... }:
{
  networking.hostName = "vm-200";

  # On-demand DMZ services: each VM sits stopped and boots on the first request
  # via a socket-activated proxy here, shutting down after idle. Traefik points
  # at the local proxy ports instead of the VMs. The proxmox-api-token (reused
  # terraform Administrator token) grants VM.PowerMgmt. sync.sh wakes these for
  # deploys. Prometheus InstanceDown excludes them (vm-103) so idle != alert.
  sops.secrets.proxmox-api-token = {};
  homelab.onDemand = {
    enable = true;
    node = "luca-server";
    tokenFile = config.sops.secrets.proxmox-api-token.path;
    services = {
      searxng    = { vmid = 202; listenPort = 26202; target = "10.200.0.202"; targetPort = 80; };
      privatebin = { vmid = 204; listenPort = 26204; target = "10.200.0.204"; targetPort = 80; };
      share      = { vmid = 205; listenPort = 26205; target = "10.200.0.205"; targetPort = 80; };
      minecraft  = { vmid = 207; listenPort = 26565; target = "10.200.0.207"; targetPort = 25565; bootTimeout = 300; };
    };
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-external")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-external");

  homelab.traefik = {
    enable = true;

    # Public-facing ingress: turn CrowdSec from log-only into an enforcing
    # bouncer (community blocklist + local bans) on every route. AppSec/WAF is
    # enabled once the bouncer itself is verified.
    crowdsecBouncer.enable = true;

    entryPoints.minecraft.address = ":25565";

    routers = {
      headscale-tls    = { rule = "Host(`hs.lsck0.dev`)";          service = "headscale";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      searxng-tls      = { rule = "Host(`search.lsck0.dev`)";      service = "searxng";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      shlink-tls       = { rule = "Host(`shlink.lsck0.dev`)";      service = "shlink";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      privatebin-tls   = { rule = "Host(`paste.lsck0.dev`)";       service = "privatebin";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      share-tls        = { rule = "Host(`share.lsck0.dev`)";       service = "share";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      hello-tls        = { rule = "Host(`hello.lsck0.dev`)";       service = "hello";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      ntfy-tls         = { rule = "Host(`ntfy.lsck0.dev`)";        service = "ntfy";         entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      # The calendar lives on the internal side; only this one host is relayed
      # through, so the TRMNL cloud can poll it without the DMZ reaching in.
      calendar-tls     = { rule = "Host(`cal.lsck0.dev`)";         service = "calendar";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
    };

    services = {
      headscale.loadBalancer.servers    = [{ url = "http://10.200.0.201:80"; }];
      # on-demand: point at the local socket-proxy, not the VM directly.
      searxng.loadBalancer.servers      = [{ url = "http://127.0.0.1:26202"; }];
      shlink.loadBalancer.servers       = [{ url = "http://10.200.0.203:80"; }];
      privatebin.loadBalancer.servers   = [{ url = "http://127.0.0.1:26204"; }];
      share.loadBalancer.servers        = [{ url = "http://127.0.0.1:26205"; }];
      hello.loadBalancer.servers        = [{ url = "http://10.200.0.208:80"; }];
      ntfy.loadBalancer.servers         = [{ url = "http://10.200.0.206:80"; }];
      calendar.loadBalancer.servers     = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
    };

    # Traefik takes SNI from the server URL, which is an IP here, so the
    # internal instance has to be told which certificate to present.
    serversTransports.internal-traefik.serverName = "cal.lsck0.dev";

    tcp = {
      routers.minecraft = {
        rule = "HostSNI(`*`)";
        service = "minecraft";
        entryPoints = [ "minecraft" ];
      };
      services.minecraft.loadBalancer.servers = [{ address = "127.0.0.1:26565"; }];
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
