# the edge: the only host the internet reaches (the router forwards the public address's https here)
#
# Public routes (modules/catalog.nix) go to their guest or the swarm with their protection (modules/traefik);
# every internal route is relayed to the internal ingress over tls verified for its host, so authelia decides there.
# A host no router names gets a 404 here, nothing travels inward for it.
{ config, lib, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  service = import ../../modules/service.nix { inherit lib; };

  # the internal ingress's own pages, relayed like its routes
  ingressPages = lib.genAttrs (lib.attrValues net.ingressPages) (host: {
    inherit host;
    path = "/";
    off = { };
    frames = "deny";
    referrer = true;
    bodyLimitBytes = service.bodyLimitDefaultBytes;
    sources = null;
  });

  # an app's own metrics stay off the internet whatever prefix serves them (catalog.metricsBlocks)
  metricsBlockName = b: "${b.app}${lib.replaceStrings [ "/" ] [ "-" ] b.path}-metrics-block";
  # above every route, bot defence included
  metricsBlockPriority = 10000;

  # `curl <host>.lsck0.dev | sh` lines, answered by the local nginx
  installHosts = import ../../modules/install-hosts.nix;
  installPort = 8084;
  installRule = lib.concatMapStringsSep " || " (h: "Host(`${net.fqdn h}`)") (lib.attrNames installHosts);
in {
  homelab.onDemand = {
    enable = true;
    side = "external";
  };

  homelab.traefik = {
    enable = true;
    routes = catalog.external;
    relays = catalog.internal // ingressPages;
    relayTarget = "https://${net.ipOf net.zones.internal.ingress}:${toString net.ports.https}";

    # cloudflare connects here and appends the client it saw
    trustCloudflare = true;
    crowdsecBouncer = { enable = true; whitelistCidrs = net.privateRanges; };
    botDefense.enable = true;
    cloudflareOnly.enable = true;

    loopbackPorts = { install-nginx = installPort; }
      // lib.mapAttrs' (name: svc: lib.nameValuePair "ondemand-${name}" svc.listenPort) config.homelab.onDemand.services;

    routers = lib.listToAttrs (map (b: lib.nameValuePair (metricsBlockName b) {
      # /API/Metrics, //api/metrics/x reach one handler too; traefik already resolved dot segments and escapes
      rule = "Host(`${net.fqdn b.host}`) && PathRegexp(`(?i)^${lib.concatMapStringsSep "/+" lib.escapeRegex (lib.splitString "/" b.path)}(/|$)`)";
      service = "noop@internal";
      entryPoints = [ "websecure" ];
      priority = metricsBlockPriority;
      middlewares = [ "deny-all" ];
    }) catalog.metricsBlocks) // {
      install-tls = {
        rule = installRule;
        service = "install";
        entryPoints = [ "websecure" ];
        off.cloudflare = "the install lines are published raw for a bare arch iso's curl";
      };
    };

    services.install.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString installPort}"; }];
  };

  services.nginx = {
    enable = true;
    virtualHosts = lib.mapAttrs' (host: line: lib.nameValuePair (net.fqdn host) {
      listen = [{ addr = "127.0.0.1"; port = installPort; }];
      locations."/".extraConfig = ''
        default_type text/plain;
        return 200 "${line}\n";
      '';
    }) installHosts;
  };
}
