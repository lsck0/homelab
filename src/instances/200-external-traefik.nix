{ config, lib, pkgs, nasMount, ... }:
let
  # Anubis proof-of-work bot filter in front of the browser-facing DMZ routes.
  # Off by default: flipping this repoints each web route through its local
  # Anubis instance (Traefik points at 272xx instead of the upstream/on-demand
  # 262xx port). A real browser solves one JS challenge; AI crawlers and
  # headless scrapers that ignore it are dropped before they reach the app.
  # Not applied to headscale (tailscale client API), ntfy (app polling),
  # calendar (TRMNL polling) or minecraft (raw TCP) — none are browsers.
  anubisEnable = false;
  # Traefik server URL for a browser-facing service: the Anubis instance when
  # the filter is on, the original upstream when off.
  fronted = anubisPort: upstream:
    if anubisEnable then "http://127.0.0.1:${toString anubisPort}" else upstream;
in {
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

    # Deny public access to internal-only services that have no auth of their own
    # and are headless (so Authelia's browser redirect can't gate them). Requests
    # here arrive from the Cloudflare edge (a public peer), so an ipAllowList of
    # private ranges rejects every public hit; LAN/VPN clients reach these via
    # split-horizon straight to the internal Traefik and never touch this box.
    middlewares.internal-only.ipAllowList.sourceRange = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    # Public-facing ingress: turn CrowdSec from log-only into an enforcing
    # bouncer (community blocklist + local bans) on every route. AppSec/WAF is
    # enabled once the bouncer itself is verified.
    crowdsecBouncer.enable = true;

    # Bot filter for the browser-facing routes. Each instance forwards to the
    # service's real upstream (an on-demand 262xx proxy for the on-demand ones,
    # the VM directly otherwise). Enable by flipping anubisEnable above.
    anubis = {
      enable = anubisEnable;
      instances = {
        searxng    = { upstream = "http://127.0.0.1:26202"; listenPort = 27202; };
        privatebin = { upstream = "http://127.0.0.1:26204"; listenPort = 27204; };
        share      = { upstream = "http://127.0.0.1:26205"; listenPort = 27205; };
        shlink     = { upstream = "http://10.200.0.203:80";  listenPort = 27203; };
        hello      = { upstream = "http://10.200.0.208:80";  listenPort = 27208; };
      };
    };

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

      # Docker registry: headless, no auth of its own, internal-only. Deny on the
      # public path; CI runner and swarm nodes reach it via split-horizon.
      registry-block = { rule = "Host(`registry.lsck0.dev`)"; service = "internal-relay"; entryPoints = [ "websecure" ]; priority = 100; middlewares = [ "internal-only" ]; tls.certResolver = "cloudflare"; };

      # Catch-all: any *.lsck0.dev host without a dedicated router above is an
      # internal service. Relay it to the internal Traefik (10.100.0.100), which
      # routes by Host header and gates it behind Authelia. Lowest priority so
      # every explicit external router wins. One wildcard cert covers all names.
      # This is the "when Cloudflare/edge doesn't know it, send it to internal"
      # path — internal services become reachable by name with no device config.
      internal-relay   = {
        rule = "HostRegexp(`^[a-z0-9-]+\\.lsck0\\.dev$`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 1;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };
    };

    services = {
      headscale.loadBalancer.servers    = [{ url = "http://10.200.0.201:80"; }];
      # Browser-facing routes go through Anubis when anubisEnable is on; each
      # `fronted` picks the 272xx instance or the original upstream. The
      # on-demand ones still terminate at the 262xx socket-proxy behind Anubis.
      searxng.loadBalancer.servers      = [{ url = fronted 27202 "http://127.0.0.1:26202"; }];
      shlink.loadBalancer.servers       = [{ url = fronted 27203 "http://10.200.0.203:80"; }];
      privatebin.loadBalancer.servers   = [{ url = fronted 27204 "http://127.0.0.1:26204"; }];
      share.loadBalancer.servers        = [{ url = fronted 27205 "http://127.0.0.1:26205"; }];
      hello.loadBalancer.servers        = [{ url = fronted 27208 "http://10.200.0.208:80"; }];
      ntfy.loadBalancer.servers         = [{ url = "http://10.200.0.206:80"; }];
      calendar.loadBalancer.servers     = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
      # Relay backend for the catch-all: forward to internal Traefik over HTTPS,
      # preserving the Host header so it routes to the right service. The client
      # Host (grafana.lsck0.dev, …) becomes the SNI, so no per-host serverName is
      # needed; insecureSkipVerify accepts whatever cert internal Traefik serves.
      internal-relay.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      internal-relay.loadBalancer.serversTransport = "internal-relay";
      internal-relay.loadBalancer.passHostHeader = true;
    };

    # Traefik takes SNI from the server URL, which is an IP here, so the
    # internal instance has to be told which certificate to present.
    serversTransports.internal-traefik.serverName = "cal.lsck0.dev";
    serversTransports.internal-relay.insecureSkipVerify = true;

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
