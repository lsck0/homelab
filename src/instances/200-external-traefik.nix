{ config, lib, nasMount, inventory, ... }:
let
  catalog = import ../modules/catalog.nix { inherit inventory lib; };
  allRoutes = catalog;
  # nixos services on a vm (routes.nix), woken on demand, and swarm apps on every apps node (apps.nix)
  routes = lib.filterAttrs (_: r: r ? vmid) catalog.external;
  appRoutes = lib.filterAttrs (_: r: r ? app) catalog.external;
  address = config.homelab.onDemand.address;

  # headless token-only hosts stay off the internet
  blockedInternal = lib.filterAttrs
    (_: r: (r.auth or "sso") == "token" && !(r.publicRelay or false))
    allRoutes.internal;
  # internal hosts relayed to the internet past cloudflare
  publicRelays = lib.filterAttrs (_: r: r.publicRelay or false) allRoutes.internal;
  internalTraefik = "https://10.100.0.100:443";

  # anubis pow filter on browser-facing routes; one more instance fronts every app route that asks for it
  anubisRoutes = [ "searxng" "privatebin" "share" ];
  anubisPort = name: 27000 + lib.lists.findFirstIndex (n: n == name) 0 (anubisRoutes ++ [ appsAnubis ]);
  upstream = name: "http://${address.${name}}";

  # anubis knows one upstream, so it hands app requests back to traefik on loopback, which picks a live node
  appsAnubis = "apps";
  appsBalancerPort = 28080;
  appsBalancer = "http://127.0.0.1:${toString appsBalancerPort}";
  # the template's limits: request bodies 1 MiB unless a path says otherwise, the methods a browser app uses
  appBodyLimitDefault = 1024 * 1024;
  appMethods = [ "GET" "HEAD" "POST" "PUT" "PATCH" "DELETE" "OPTIONS" ];
  appRule = r: "Host(`${r.host}.lsck0.dev`)" + lib.optionalString (r.prefix != "/") " && PathPrefix(`${r.prefix}`)";
  # an app's own metrics stay off the internet whatever prefix serves them
  metricsBlocks = lib.concatLists (lib.mapAttrsToList (name: a: lib.concatMap (m:
    lib.optional (lib.any (p: p.port == m.port) (lib.attrValues a.paths)) { inherit name; host = a.host or name; inherit (m) path; }
  ) (lib.attrValues (a.metrics or { }))) catalog.apps);

  # `curl <host>.lsck0.dev | sh` lines, answered by the local nginx
  installHosts = import ../modules/install-hosts.nix;
  installPort = 8084;
  installRule = lib.concatMapStringsSep " || " (h: "Host(`${h}.lsck0.dev`)") (lib.attrNames installHosts);
in {
  networking.hostName = "vm-200";

  # backends wake via homelab.onDemand
  # wake@pve!ondemand: vm status, start, shutdown only, not the terraform admin token
  sops.secrets.proxmox-wake-token = {};
  homelab.onDemand = {
    enable = true;
    side = "external";
    tokenFile = config.sops.secrets.proxmox-wake-token.path;
    services = lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair name {
      inherit (routes.${name}) vmid;
      targetPort = routes.${name}.port;
      listenPort = 20000 + i;
    }) (lib.attrNames routes));
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-external")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-external");

  homelab.traefik = {
    enable = true;

    # relay re-applies headers over internal traefik's
    sameOriginFrameRouters = [ "jellyfin-relay" ];
    # the search query is in the url
    noReferrerRouters = [ "searxng-tls" ];
    # real client ip from cloudflare's x-forwarded-for
    trustCloudflare = true;

    # crowdsec bouncer plus appsec waf everywhere
    crowdsecBouncer.enable = true;
    crowdsecBouncer.appsec = true;
    crowdsecBouncer.noAppsecRouters = [ "headscale-tls" "ntfy-tls" ]
      ++ map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: !r.waf) appRoutes));
    # the apps get the owasp core rule set on top, as webapp-template's modsecurity gave them
    crowdsecBouncer.crsRouters = map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: r.waf) appRoutes));
    # bouncer whitelist only skips decisions
    crowdsecBouncer.whitelistCidrs = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    anubis = {
      enable = true;
      instances = lib.genAttrs anubisRoutes (name: {
        upstream = upstream name;
        listenPort = anubisPort name;
      }) // {
        ${appsAnubis} = { upstream = appsBalancer; listenPort = anubisPort appsAnubis; };
      };
    };

    # robots.txt, llms.txt, iocaine for ignorers
    botDefense.enable = true;

    # origin refuses everyone but cloudflare
    cloudflareOnly.enable = true;
    cloudflareOnly.exemptRouters =
      map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: !(r.proxied or true)) routes))
      ++ map (name: "${name}-tls") (lib.attrNames publicRelays)
      ++ [ "wellknown-tls" "labyrinth-tls" "install-tls" ]
      # already private-only via internal-only
      ++ map (name: "${name}-block") (lib.attrNames blockedInternal);

    # cap bodies on small-post routes
    bodyLimits = { searxng-tls = 32 * 1024 * 1024; }
      // lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" (if r.bodyLimit == null then appBodyLimitDefault else r.bodyLimit)) appRoutes;

    entryPoints.minecraft.address = ":25565";
    # anubis' X-Forwarded-For, X-Real-Ip and -Proto carry the client; loopback is the only sender here
    entryPoints.apps-balancer = {
      address = "127.0.0.1:${toString appsBalancerPort}";
      forwardedHeaders.trustedIPs = [ "127.0.0.1/32" ];
    };

    middlewares = {
      # headless internal-only services: private ranges only
      internal-only.ipAllowList.sourceRange = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
      # browsers get the response compressed, as the template's nginx did
      apps-compress.compress = { };
    } // lib.mapAttrs' (name: a: lib.nameValuePair "${name}-headers" { headers = a.headers; })
      (lib.filterAttrs (_: a: a ? headers) catalog.apps);

    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" ({
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
      tls.certResolver = "cloudflare";
    }
    # the access log keeps the path, and so every query, for 14 days in loki
    // lib.optionalAttrs (name == "searxng") { observability.accessLogs = false; }
    )) (routes // publicRelays)
    # swarm apps: the full chain, then anubis where the path asks for it
    // lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" {
      rule = "(${appRule r}) && (${lib.concatMapStringsSep " || " (m: "Method(`${m}`)") appMethods})";
      service = if r.anubis then "apps-anubis" else name;
      entryPoints = [ "websecure" ];
      tls.certResolver = "cloudflare";
      middlewares = [ "apps-compress" ] ++ lib.optional (catalog.apps.${r.app} ? headers) "${r.app}-headers";
    }) appRoutes
    # what anubis lets through comes back here and goes to a node
    // lib.mapAttrs' (name: r: lib.nameValuePair "${name}-balancer" {
      rule = appRule r;
      service = name;
      entryPoints = [ "apps-balancer" ];
    }) appRoutes
    // lib.listToAttrs (map (b: lib.nameValuePair "${b.name}-metrics-block" {
      # with anything after it: /api/metrics/ and friends reach the same handler
      rule = "Host(`${b.host}.lsck0.dev`) && PathRegexp(`^${lib.escapeRegex b.path}(/|$)`)";
      service = "noop@internal";
      entryPoints = [ "websecure" ];
      priority = 10000;
      middlewares = [ "deny-all" ];
      tls.certResolver = "cloudflare";
    }) metricsBlocks)
    // {
      install-tls  = { rule = installRule; service = "install"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };

      # catch-all: unmatched hosts relay to internal traefik
      internal-relay = {
        rule = "HostRegexp(`^[a-z0-9-]+\\.lsck0\\.dev$`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 1;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };

      # outranks internal-relay for SAMEORIGIN
      jellyfin-relay = {
        rule = "Host(`jellyfin.lsck0.dev`)";
        service = "internal-relay";
        entryPoints = [ "websecure" ];
        priority = 10;
        tls.certResolver = "cloudflare";
        tls.domains = [{ main = "lsck0.dev"; sans = [ "*.lsck0.dev" ]; }];
      };
    }
    # one blocking router per token-only host
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
        url = if builtins.elem name anubisRoutes
          then "http://127.0.0.1:${toString (anubisPort name)}"
          else upstream name;
      }];
    }) routes // lib.mapAttrs (name: _: {
      loadBalancer.servers = [{ url = internalTraefik; }];
      loadBalancer.serversTransport = name;
    }) publicRelays
    // lib.mapAttrs (name: r: {
      loadBalancer = {
        servers = map (ip: { url = "http://${ip}:${toString r.port}"; }) r.nodes;
      } // lib.optionalAttrs (r.health != null) {
        # a node down or draining drops out of the rotation
        healthCheck = { path = r.health; interval = "10s"; timeout = "3s"; };
      };
    }) appRoutes // {
      apps-anubis.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString (anubisPort appsAnubis)}"; }];
      install.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString installPort}"; }];
      # catch-all relay to internal traefik over https
      internal-relay.loadBalancer.servers = [{ url = internalTraefik; }];
      internal-relay.loadBalancer.serversTransport = "internal-relay";
      internal-relay.loadBalancer.passHostHeader = true;
    };

    # sni comes from the url, an ip here; internal traefik has one cert per host, no wildcard
    serversTransports = lib.mapAttrs (_: r: { serverName = "${r.host}.lsck0.dev"; }) publicRelays // {
      # any host, so no single name to verify against
      internal-relay.insecureSkipVerify = true;
    };

    tcp = {
      routers.minecraft = {
        rule = "HostSNI(`*`)";
        service = "minecraft";
        entryPoints = [ "minecraft" ];
      };
      # straight to lazymc on vm-208, which fronts the game port
      services.minecraft.loadBalancer.servers = [{ address = "10.200.0.208:25565"; }];
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts = lib.mapAttrs' (host: line: lib.nameValuePair "${host}.lsck0.dev" {
      listen = [{ addr = "127.0.0.1"; port = installPort; }];
      locations."/".extraConfig = ''
        default_type text/plain;
        return 200 "${line}\n";
      '';
    }) installHosts;
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
