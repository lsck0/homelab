{ config, lib, nasMount, ... }:
let
  routes = (import ../modules/routes.nix).external;
  address = config.homelab.onDemand.address;

  # Anubis PoW bot filter on the browser-facing routes: on = Traefik points at
  # the Anubis instance, off = straight to the upstream. Not for the non-browser
  # routes (headscale/ntfy/calendar/minecraft).
  # off: behind Cloudflare, Anubis only ever sees the rotating edge IP (the real
  # client isn't recoverable here), so it re-challenges every request and breaks
  # CSS. External is protected by CrowdSec + AppSec WAF + rate-limits instead.
  # the module stays wired: flip on if the client-IP handling is ever solved.
  anubisEnable = false;
  anubisRoutes = [ "searxng" "shlink" "privatebin" "share" "hello" "hello-gh" ];
  anubisPort = name: 27000 + lib.lists.findFirstIndex (n: n == name) 0 anubisRoutes;
  upstream = name: "http://${address.${name}}";
in {
  networking.hostName = "vm-200";

  # every backend goes through homelab.onDemand: VMs with enabled = "onDemand"
  # in instances.tf get a wake proxy on this host, the rest are reached directly.
  sops.secrets.proxmox-api-token = {};
  homelab.onDemand = {
    enable = true;
    side = "external";
    tokenFile = config.sops.secrets.proxmox-api-token.path;
    services = lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair name {
      inherit (routes.${name}) vmid;
      targetPort = routes.${name}.port;
      listenPort = 20000 + i;
    }) (lib.attrNames routes)) // {
      # raw TCP: the wake proxy holds the player's connection while the VM boots.
      minecraft = { vmid = 208; targetPort = 25565; listenPort = 25566; bootTimeout = 300; httpCheck = false; };
    };
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-external")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-external");

  homelab.traefik = {
    enable = true;
    # behind Cloudflare: take the real client IP from X-Forwarded-For so Anubis
    # and CrowdSec see a stable client, not the rotating edge IP.
    trustCloudflare = true;

    # deny public access to headless internal-only services (no own auth): every
    # request here comes from the Cloudflare edge, so a private-range allowlist
    # rejects it; LAN/VPN reach them directly via split-horizon.
    middlewares.internal-only.ipAllowList.sourceRange = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    # CrowdSec bouncer (blocklist + bans) + AppSec/WAF on every route, except
    # headscale/ntfy (non-browser APIs the WAF would break, IP bouncer only).
    crowdsecBouncer.enable = true;
    crowdsecBouncer.appsec = true;
    crowdsecBouncer.noAppsecRouters = [ "headscale-tls" "ntfy-tls" ];
    # never self-ban the LAN or the home network (real IPv6 prefix may rotate).
    crowdsecBouncer.whitelistCidrs = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "2003:f7:8f3a::/48"
    ];

    anubis = {
      enable = anubisEnable;
      instances = lib.genAttrs anubisRoutes (name: {
        upstream = upstream name;
        listenPort = anubisPort name;
      });
    };

    entryPoints.minecraft.address = ":25565";

    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" {
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
      tls.certResolver = "cloudflare";
    }) routes // {
      # the calendar lives on the internal side; only this one host is relayed
      # through, so the TRMNL cloud can poll it without the DMZ reaching in.
      calendar-tls   = { rule = "Host(`cal.lsck0.dev`)"; service = "calendar"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };

      # Docker registry: headless, no auth of its own, internal-only. Deny on the
      # public path; CI runner and swarm nodes reach it via split-horizon.
      registry-block = { rule = "Host(`registry.lsck0.dev`)"; service = "internal-relay"; entryPoints = [ "websecure" ]; priority = 100; middlewares = [ "internal-only" ]; tls.certResolver = "cloudflare"; };

      # catch-all (lowest priority): any *.lsck0.dev not matched above is an
      # internal service: relay to internal Traefik (routes by Host, Authelia-gated).
      # one wildcard cert covers all names.
      internal-relay = {
        rule = "HostRegexp(`^[a-z0-9-]+\\.lsck0\\.dev$`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 1;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };
    };

    services = lib.mapAttrs (name: _: {
      loadBalancer.servers = [{
        url = if anubisEnable && builtins.elem name anubisRoutes
          then "http://127.0.0.1:${toString (anubisPort name)}"
          else upstream name;
      }];
    }) routes // {
      calendar.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
      # relay backend for the catch-all: forward to internal Traefik over HTTPS,
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
      services.minecraft.loadBalancer.servers = [{ address = address.minecraft; }];
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
