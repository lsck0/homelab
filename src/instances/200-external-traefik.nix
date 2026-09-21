{ config, lib, nasMount, ... }:
let
  allRoutes = import ../modules/routes.nix;
  routes = allRoutes.external;
  address = config.homelab.onDemand.address;

  # internal hosts that must NOT be reachable from the internet: headless
  # routes whose only credential is an API token, so a browser cannot log in
  # and Authelia cannot protect them. The catch-all below would otherwise relay
  # them like any other internal name. LAN and the Headscale mesh still reach
  # them directly through split-horizon DNS.
  # (calendar opts back in with publicRelay: the TRMNL cloud has to poll it.)
  blockedInternal = lib.filterAttrs
    (_: r: !(r.publicRelay or ((r.auth or "sso") != "token")))
    allRoutes.internal;

  # Anubis PoW bot filter on the browser-facing routes: on = Traefik points at
  # the Anubis instance, off = straight to the upstream. Not for the non-browser
  # routes (headscale/ntfy/calendar/minecraft).
  #
  # This was off because Anubis only ever saw the Cloudflare edge address and
  # therefore re-challenged every request, which loaded pages without their CSS.
  # Both halves of that are now fixed in modules/traefik.nix: the instances run
  # with USE_REMOTE_ADDRESS=false so they take the client from the X-Real-Ip
  # Traefik sets (already the real visitor, because trustCloudflare makes the
  # edge ranges trusted on this entrypoint), and COOKIE_DOMAIN is the apex so
  # one solved challenge covers every host and every sub-resource.
  #
  # Kill switch: set this back to false and redeploy vm-200.
  anubisEnable = true;
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

    # the relay re-applies its own headers on top of the internal Traefik's, so
    # the SAMEORIGIN exemption for jellyfin-plugin-sso has to be set here too.
    # internal-relay is a single catch-all router for every internal host, so
    # jellyfin gets its own higher-priority copy below rather than loosening
    # X-Frame-Options for all of them.
    sameOriginFrameRouters = [ "jellyfin-relay" ];
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

    # robots.txt + llms.txt on every public host, and iocaine for the crawlers
    # that ignore both. Anubis stops headless clients that cannot run the
    # challenge; this catches the ones that identify themselves honestly and
    # crawl anyway, and costs them rather than us.
    botDefense.enable = true;

    # Cloudflare is only a chokepoint if the origin turns away everyone else.
    # Exempt exactly the hosts whose DNS record is not proxied (`proxied` in
    # routes.nix): nothing forwards those through the edge, so restricting them
    # would take them off the internet. robots.txt/llms.txt and the labyrinth
    # stay open too - a crawler has to be able to read the file telling it to go
    # away, and one that ignores it should still reach the maze.
    cloudflareOnly.enable = true;
    cloudflareOnly.exemptRouters =
      map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: !(r.proxied or true)) routes))
      ++ [ "calendar-tls" "wellknown-tls" "labyrinth-tls" ]
      # already restricted to private ranges by the internal-only middleware.
      ++ map (name: "${name}-block") (lib.attrNames blockedInternal);

    # cap request bodies on the routes that only ever take small posts. Left
    # out on purpose: share and privatebin exist to receive files, and
    # internal-relay carries Nextcloud and Paperless uploads. Traefik has to
    # buffer a body to measure it, so a limit there would stall those.
    bodyLimit = 32 * 1024 * 1024;
    bodyLimitRouters = [ "searxng-tls" "shlink-tls" "hello-tls" "hello-gh-tls" ];

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

      # same upstream as internal-relay, but outranks it so the SAMEORIGIN
      # header applies to Jellyfin alone. Its SSO plugin finishes the login in
      # a hidden same-origin iframe that X-Frame-Options: DENY blocks, which
      # leaves the browser sitting on "Logging in..." for ever.
      jellyfin-relay = {
        rule = "Host(`jellyfin.lsck0.dev`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 10;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };
    }
    # one higher-priority router per token-only internal host, carrying the
    # private-range allowlist: every request off the internet arrives from the
    # Cloudflare edge and is rejected there.
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
