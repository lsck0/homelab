# lab-wide: every feature is off until a service opts in, and protection is per path
# The real tree plus a bare internal guest, a bare external one, a hardened one and a bare app
# (src/modules/service.nix): a service without `on` is a router to its port on its ingress with the plumbing alone (the
# real client, the strip of client-sent identity headers, the retry), no card, no probe, no scrape, no guard on its
# port; an internal one has no public name, an external one its raw public name and nothing more. Its guest's firewall
# opens ssh, node-exporter and its http port. Per path, one host and one backend: `/api` rate limited under a plain
# `/`, a plain `/public` under a hardened `/`, each prefix ranked above its parent.
{ pkgs, lib, inputs, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  inherit ((import ../modules/lab { inherit lib; }).layout) preconfigured custom;
  bare = { id = "199"; folder = "199-internal-bare"; port = 80; };
  hardened = { id = "198"; folder = "198-internal-hardened"; port = 80; };
  open = { id = "249"; folder = "249-external-open"; port = 80; };
  app = { name = "plain"; port = 20190; };
  # every router's own: the real client, the strip of what a client claims, the retry
  plumbing = [ "client-ip" "strip-client-headers" "retry-upstream" ];
  rateLimits = [ "rate-limit" "route-rate-limit" ];

  instances = {
    ${bare.folder} = ''
      { ... }: {
        services.bare.port = ${toString bare.port};
        services.bare-api = { host = "bare"; path = "/api"; port = ${toString bare.port}; on = [ "rateLimit" ]; };
      }
    '';
    ${open.folder} = "{ ... }: { services.open.port = ${toString open.port}; }";
    ${hardened.folder} = ''
      { profiles, ... }: {
        services.hardened = { port = ${toString hardened.port}; on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed; };
        services.hardened-public = { host = "hardened"; path = "/public"; port = ${toString hardened.port}; };
      }
    '';
  };
  appNix = pkgs.writeText "app.nix" ''
    { ... }: {
      enable = true;
      repo = "lsck0/${app.name}";
      branch = "master";
      routes.${app.name}.port = ${toString app.port};
      routes.${app.name}-api = { host = "${app.name}"; path = "/api"; port = ${toString app.port}; on = [ "rateLimit" ]; };
    }
  '';
  tree = pkgs.runCommand "lab-opt-in" { } (''
    cp -r ${./..} $out && chmod -R u+w $out
    mkdir -p $out/${custom}/${app.name}
    cp ${appNix} $out/${custom}/${app.name}/app.nix
  '' + lib.concatStrings (lib.mapAttrsToList (folder: text: ''
    mkdir -p $out/${preconfigured}/${folder}
    cp ${pkgs.writeText "main.nix" "{ ... }: { }"} $out/${preconfigured}/${folder}/main.nix
    cp ${pkgs.writeText "instance.nix" text} $out/${preconfigured}/${folder}/instance.nix
  '') instances));

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  grown = import ../modules/lab { inherit lib; root = tree; };
  net = import ../modules/net.nix { inherit lib; inherit (grown) inventory site; };
  configOf = host: (inputs.self.lib.hostOf grown host).config;
  routersOf = host: (configOf host).services.traefik.dynamicConfigOptions.http.routers;
  internal = routersOf "100-internal-traefik";
  edge = routersOf "200-external-traefik";
  grafana = configOf "105-internal-grafana";
  router = configOf "300-router";
  guestOf = i: configOf i.folder;
  # a router's rank among a host's: its priority, else its rule's length (traefik's own default)
  rankOf = r: r.priority or (lib.stringLength r.rule);
  # the routers serving a route: its own and its splits by body and socket
  partsOf = routers: name: lib.filterAttrs (n: _: n == name || lib.hasPrefix "${name}-" n && !(lib.hasInfix "probe" n)) routers;
  outranks = routers: child: parent: lib.all (p: rankOf routers.${child} > rankOf p) (lib.attrValues (partsOf routers parent));
  # everything a guest's firewall admits: its port lists, and the ports of its own rules (node-exporter's openFirewall)
  opened = config: let fw = config.networking.firewall; in {
    tcp = lib.sort lib.lessThan fw.allowedTCPPorts;
    udp = fw.allowedUDPPorts;
    ranges = fw.allowedTCPPortRanges ++ fw.allowedUDPPortRanges;
    rules = map (m: lib.toInt (lib.head m)) (lib.filter lib.isList (builtins.split "--dports? ([0-9]+)" fw.extraCommands));
    interfaces = lib.filter (i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ]) (lib.attrValues fw.interfaces);
  };
  ddnsRecords = builtins.fromJSON (builtins.readFile router.systemd.services.ddns-cloudflare.environment.DDNS_RECORDS);
  recordOf = host: lib.findFirst (r: r.name == net.fqdn host) null ddnsRecords;
  scrapes = builtins.toJSON grafana.services.prometheus.scrapeConfigs;
  bareRoute = grown.routes.bare;

  # -----------------------------------------------------------------------------
  # CHECKS
  # -----------------------------------------------------------------------------

  checks = {
    "the lab holds" = grown.problems == [ ];
    "a bare route is a router with the plumbing alone" = internal.bare-tls.middlewares == plumbing;
    "a bare route goes to its port" = (configOf "100-internal-traefik").services.traefik.dynamicConfigOptions.http.services.bare.loadBalancer.servers
      == [ { url = "http://${net.ipOf bare.id}:${toString bare.port}"; } ];
    "a bare route has no other router" = lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "bare-" n) internal) == [ "bare-api-tls" "bare-tls" ];
    "a bare route has no card" = !(lib.any (c: c.route == "bare") grown.homepage);
    "a bare route takes no feature" = !(lib.any lib.id (lib.attrValues grown.catalog.services.bare.on));
    "a bare route is neither probed nor scraped" = !(lib.hasInfix (grown.catalog.probeUrlOf bareRoute) scrapes)
      && !(lib.hasInfix "service-bare-" scrapes);
    "a bare route has no public name" = recordOf "bare" == null;
    "a bare route is relayed to the lab alone" = edge.bare-relay.middlewares == plumbing ++ [ "internal-only" ];
    "a bare guest opens ssh, node-exporter and its http port" = opened (guestOf bare)
      == { tcp = lib.sort lib.lessThan [ net.ports.ssh bare.port ]; udp = [ ]; ranges = [ ]; rules = [ net.ports.nodeExporter ]; interfaces = [ ]; };
    "a bare guest guards no port" = (guestOf bare).homelab.ingressOnly.ports == [ ];
    "a bare external route is an edge router with the plumbing alone" = edge.open-tls.middlewares == plumbing
      && lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix "open-" n) edge) == [ "open-tls" ];
    "a bare external route has its raw public name" = lib.all (host: recordOf host == { name = net.fqdn host; proxied = false; })
      [ "open" app.name ];
    "a bare external route has no card" = !(lib.any (c: c.route == "open") grown.homepage);
    "a bare external guest opens ssh, node-exporter and its http port, guarding none" = opened (guestOf open)
      == { tcp = lib.sort lib.lessThan [ net.ports.ssh open.port ]; udp = [ ]; ranges = [ ]; rules = [ net.ports.nodeExporter ]; interfaces = [ ]; }
      && (guestOf open).homelab.ingressOnly.ports == [ ];
    "a bare app route is a router with the plumbing alone" = edge."${app.name}-tls".middlewares == plumbing ++ [ "compress" ];

    "a rate limited /api under a plain / limits /api alone" = internal.bare-api-tls.middlewares == lib.take 2 plumbing ++ rateLimits ++ [ "retry-upstream" ];
    "a rate limited /api outranks its plain /" = outranks internal "bare-api-tls" "bare-tls";
    "an app's rate limited /api under a plain / limits /api alone" = lib.all (m: lib.elem m edge."${app.name}-api-tls".middlewares) rateLimits
      && outranks edge "${app.name}-api-tls" "${app.name}-tls";
    "a plain /public under a hardened / is plain" = internal.hardened-public-tls.middlewares == plumbing;
    "a plain /public outranks its hardened /" = outranks internal "hardened-public-tls" "hardened-tls";
    "a hardened / takes authelia" = lib.elem "authelia" internal.hardened-tls.middlewares;
    "a hardened route has its card, its proxied name and its guard" = lib.any (c: c.route == "hardened") grown.homepage
      && (recordOf "hardened").proxied && (guestOf hardened).homelab.ingressOnly.ports == [ hardened.port ];
    "the relay of a plain /public outranks its parent's" = rankOf edge.hardened-public-relay > rankOf edge.hardened-relay;
  };
  failures = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
pkgs.runCommand "opt-in" { } (if failures == [ ] then ''
  echo "opt-in: ${toString (lib.length (lib.attrNames checks))} checks hold"
  touch $out
'' else ''
  echo "opt-in: ${lib.concatStringsSep "; " failures}" >&2
  exit 1
'')
