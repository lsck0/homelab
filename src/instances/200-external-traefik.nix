{ config, lib, nasMount, ... }:
let
  allRoutes = import ../modules/routes.nix;
  routes = allRoutes.external;
  address = config.homelab.onDemand.address;

  # internal hosts that must NOT be reachable from the internet: headless routes whose
  blockedInternal = lib.filterAttrs
    (_: r: !(r.publicRelay or ((r.auth or "sso") != "token")))
    allRoutes.internal;

  # Anubis PoW bot filter on the browser-facing routes: on = Traefik points at the Anubis
  anubisEnable = true;
  anubisRoutes = [ "searxng" "shlink" "privatebin" "share" "hello" "hello-gh" ];
  anubisPort = name: 27000 + lib.lists.findFirstIndex (n: n == name) 0 anubisRoutes;
  upstream = name: "http://${address.${name}}";
in {
  networking.hostName = "vm-200";

  # every backend goes through homelab.onDemand: VMs with enabled = "onDemand" in instances.tf
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

    # the relay re-applies its own headers on top of the internal Traefik's
    sameOriginFrameRouters = [ "jellyfin-relay" ];
    # behind Cloudflare: take the real client IP from X-Forwarded-For so Anubis and CrowdSec
    trustCloudflare = true;

    # deny public access to headless internal-only services (no own auth): every request here
    middlewares.internal-only.ipAllowList.sourceRange = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    # CrowdSec bouncer (blocklist + bans) + AppSec/WAF on every route
    crowdsecBouncer.enable = true;
    crowdsecBouncer.appsec = true;
    crowdsecBouncer.noAppsecRouters = [ "headscale-tls" "ntfy-tls" ];
    # The bouncer's own whitelist, which only stops it acting on a decision.
    crowdsecBouncer.whitelistCidrs = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    anubis = {
      enable = anubisEnable;
      instances = lib.genAttrs anubisRoutes (name: {
        upstream = upstream name;
        listenPort = anubisPort name;
      });
    };

    # robots.txt + llms.txt on every public host, and iocaine for the crawlers that ignore both.
    botDefense.enable = true;

    # Cloudflare is only a chokepoint if the origin turns away everyone else.
    cloudflareOnly.enable = true;
    cloudflareOnly.exemptRouters =
      map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: !(r.proxied or true)) routes))
      ++ [ "calendar-tls" "terminal-tls" "wellknown-tls" "labyrinth-tls" ]
      # already restricted to private ranges by the internal-only middleware.
      ++ map (name: "${name}-block") (lib.attrNames blockedInternal);

    # cap request bodies on the routes that only ever take small posts.
    bodyLimit = 32 * 1024 * 1024;
    bodyLimitRouters = [ "searxng-tls" "shlink-tls" "hello-tls" "hello-gh-tls" ];

    entryPoints.minecraft.address = ":25565";

    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" {
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
      tls.certResolver = "cloudflare";
    }) routes // {
      # the calendar lives on the internal side; only this one host is relayed through
      calendar-tls   = { rule = "Host(`cal.lsck0.dev`)"; service = "calendar"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      # same for the terminal's stats feed.
      terminal-tls   = { rule = "Host(`terminal.lsck0.dev`)"; service = "calendar"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };

      # catch-all (lowest priority): any *.lsck0.dev not matched above is an internal service
      internal-relay = {
        rule = "HostRegexp(`^[a-z0-9-]+\\.lsck0\\.dev$`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 1;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };

      # same upstream as internal-relay, but outranks it so the SAMEORIGIN header applies
      jellyfin-relay = {
        rule = "Host(`jellyfin.lsck0.dev`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 10;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };
    }
    # one higher-priority router per token-only internal host
    // lib.mapAttrs' (name: r: lib.nameValuePair "${name}-block" {
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = "internal-relay";
      entryPoints = [ "websecure" ];
      priority = 100;
      middlewares = [ "internal-only" ];
      tls.certResolver = "cloudflare";
    }) blockedInternal;

    services = lib.mapAttrs (name: _: {
      loadBalancer.servers = [{
        url = if anubisEnable && builtins.elem name anubisRoutes
          then "http://127.0.0.1:${toString (anubisPort name)}"
          else upstream name;
      }];
    }) routes // {
      calendar.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
      # relay backend for the catch-all: forward to internal Traefik over HTTPS
      internal-relay.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      internal-relay.loadBalancer.serversTransport = "internal-relay";
      internal-relay.loadBalancer.passHostHeader = true;
    };

    # Traefik takes SNI from the server URL, which is an IP here
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
