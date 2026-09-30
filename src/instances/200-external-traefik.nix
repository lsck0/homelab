{ config, lib, nasMount, ... }:
let
  allRoutes = import ../modules/routes.nix;
  routes = allRoutes.external;
  address = config.homelab.onDemand.address;

  # headless token-only hosts stay off the internet
  blockedInternal = lib.filterAttrs
    (_: r: !(r.publicRelay or ((r.auth or "sso") != "token")))
    allRoutes.internal;

  # anubis pow filter on browser-facing routes
  anubisEnable = true;
  anubisRoutes = [ "searxng" "privatebin" "share" "hello" ];
  anubisPort = name: 27000 + lib.lists.findFirstIndex (n: n == name) 0 anubisRoutes;
  upstream = name: "http://${address.${name}}";

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
    # minecraft (208) is no longer onDemand: lazymc on the vm handles sleep/wake itself
    # (a public port is scanned constantly, which defeats a blind tcp wake proxy).
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-external")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-external");

  homelab.traefik = {
    enable = true;

    # relay re-applies headers over internal traefik's
    sameOriginFrameRouters = [ "jellyfin-relay" ];
    # real client ip from cloudflare's x-forwarded-for
    trustCloudflare = true;

    # headless internal-only services: private ranges only
    middlewares.internal-only.ipAllowList.sourceRange = [
      "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
    ];

    # crowdsec bouncer plus appsec waf everywhere
    crowdsecBouncer.enable = true;
    crowdsecBouncer.appsec = true;
    crowdsecBouncer.noAppsecRouters = [ "headscale-tls" "ntfy-tls" ];
    # bouncer whitelist only skips decisions
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

    # robots.txt, llms.txt, iocaine for ignorers
    botDefense.enable = true;

    # origin refuses everyone but cloudflare
    cloudflareOnly.enable = true;
    cloudflareOnly.exemptRouters =
      map (name: "${name}-tls") (lib.attrNames (lib.filterAttrs (_: r: !(r.proxied or true)) routes))
      ++ [ "calendar-tls" "terminal-tls" "wellknown-tls" "labyrinth-tls" "install-tls" ]
      # already private-only via internal-only
      ++ map (name: "${name}-block") (lib.attrNames blockedInternal);

    # cap bodies on small-post routes
    bodyLimit = 32 * 1024 * 1024;
    bodyLimitRouters = [ "searxng-tls" "hello-tls" ];

    entryPoints.minecraft.address = ":25565";

    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" {
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
      tls.certResolver = "cloudflare";
    }) routes // {
      # calendar is internal, only this host is relayed
      calendar-tls   = { rule = "Host(`cal.lsck0.dev`)"; service = "calendar"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      # same for the terminal stats feed
      terminal-tls   = { rule = "Host(`terminal.lsck0.dev`)"; service = "calendar"; entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };

      # bare curl speaks http and follows no redirect, so these answer on web too
      install-http = { rule = installRule; service = "install"; entryPoints = [ "web" ]; middlewares = [ "crowdsec" "rate-limit" ]; };
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
        url = if anubisEnable && builtins.elem name anubisRoutes
          then "http://127.0.0.1:${toString (anubisPort name)}"
          else upstream name;
      }];
    }) routes // {
      calendar.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
      install.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString installPort}"; }];
      # catch-all relay to internal traefik over https
      internal-relay.loadBalancer.servers = [{ url = "https://10.100.0.100:443"; }];
      internal-relay.loadBalancer.serversTransport = "internal-relay";
      internal-relay.loadBalancer.passHostHeader = true;
    };

    # sni comes from the url, an ip here
    serversTransports.internal-traefik.serverName = "cal.lsck0.dev";
    serversTransports.internal-relay.insecureSkipVerify = true;

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
