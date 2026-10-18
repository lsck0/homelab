# the anti-bot laws, over the ingresses' rendered gate (modules/traefik lib/gate) and its middlewares
#
# Never hit: the house, wireguard, the internal zone and the ingress itself pass every gate untouched, as crowdsec
# never decides against them; a logged-in user is asked about. As the route opts in: a route taking crowdsec has the
# gate, which asks the captcha, limits anonymous clients and holds banned ones where the route takes each, read off
# the forwardauth address of its router. Onion captcha: every router on the onion entrypoint asks the captcha, no
# route can say otherwise, and the gate knows every onion address it guards. No lab host logs the captcha's answers.
{ lib, configs, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  cidr = import ../../modules/cidr.nix { inherit lib; };

  ingresses = { vm-100 = configs."100-internal-traefik"; vm-200 = configs."200-external-traefik"; };
  edge = ingresses.vm-200;
  httpOf = config: config.services.traefik.dynamicConfigOptions.http;
  gateOf = config: config.homelab.traefik.gate.settings;

  # the networks no defence may ever stop, each by an address inside it; the gate also passes the ingress's own calls
  neverHit = {
    "the house lan" = net.wan.subnet;
    "wireguard" = net.wireguard.subnet;
    "the internal zone" = net.zones.internal.subnet;
  };
  gateNeverHit = neverHit // { "the ingress itself" = "127.0.0.1/32"; };
  # the house behind cloudflare by the names the router serves: its v4 address, every address of its v6 prefix
  houseHosts = {
    "v4 address" = { name = net.fqdn net.wan.publicHost; network = "ip4"; bits = 32; };
    "v6 prefix" = { name = net.fqdn net.wan.publicPrefixHost; network = "ip6"; bits = net.wan.publicPrefixLength; };
  };
  covered = ranges: network: lib.any (range: cidr.contains range (lib.head (lib.splitString "/" network))) ranges;

  # the gate's features in a router's chain: the query of its forwardauth address
  gateFlags = config: router: let
    middleware = lib.findFirst (m: lib.hasPrefix "gate" m) null (router.middlewares or [ ]);
    address = (httpOf config).middlewares.${middleware}.forwardAuth.address or "";
    query = lib.last (lib.splitString "?" address);
    pairs = map (p: lib.splitString "=" p) (lib.splitString "&" query);
  in if middleware == null then null else lib.listToAttrs (map (p: lib.nameValuePair (lib.head p) (lib.last p)) pairs);

  # a route's own routers on the edge: its route router and its relay, either of which the edge has
  edgeRoutersOf = name: lib.filterAttrs (router: _: lib.elem router [ "${name}-tls" "${name}-relay" ]) (httpOf edge).routers;
  features = { captcha = "captcha"; limit = "anonymousLimit"; tarpit = "tarpit"; };
  edgeRoutes = catalog.external // catalog.internal;

  # the edge's onion entrypoint (the one at tor's onionIngress port) and every router on it
  torPorts = import ../../modules/tor-ports.nix;
  onionEntryPoints = lib.attrNames (lib.filterAttrs (_: e: e.address or "" == ":${toString torPorts.onionIngress}")
    edge.services.traefik.staticConfigOptions.entryPoints);
  onionRouters = lib.filterAttrs (_: router: lib.any (e: lib.elem e onionEntryPoints) (router.entryPoints or [ ])) (httpOf edge).routers;
  onionAddresses = lib.filter (address: address != null) (map (r: r.onionAddress or null) (lib.attrValues catalog.external));

  # robots.txt: the lab's disallow-all on every defended host, the backend's own on an indexable route's
  robotsRule = (httpOf edge).routers.robots-tls.rule;
  edgeHttp = lib.filter (r: r.protocol == "http") (lib.attrValues catalog.external);
  hostsOf = pred: lib.unique (map (r: r.host) (lib.filter pred edgeHttp));
  robotsSpared = host: lib.hasInfix "!Host(`${net.fqdn host}`)" robotsRule;
  indexableHosts = hostsOf (r: r.indexable);
  robotsCovered = lib.subtractLists (hostsOf (r: r.indexable || !(lib.elem "botDefense" r.on))) (hostsOf (_: true));
  crowdsecCollections = lib.splitString " " (edge.virtualisation.oci-containers.containers.crowdsec.environment.COLLECTIONS or "");
in
lib.concatLists (lib.mapAttrsToList (law: violations: map (v: "${law}: ${v}") violations) {
  "never hit" = lib.concatLists (lib.mapAttrsToList (host: config: let
    settings = gateOf config;
    whitelist = config.homelab.traefik.crowdsecBouncer.whitelistCidrs;
  in
    lib.concatLists (lib.mapAttrsToList (what: network:
      lib.optional (!(covered settings.allow.cidrs network)) "${host}'s gate stops ${what} (${network})") gateNeverHit)
    ++ lib.concatLists (lib.mapAttrsToList (what: network:
      lib.optional (!(covered whitelist network)) "${host}'s crowdsec may ban ${what} (${network})") neverHit)
    ++ lib.concatLists (lib.mapAttrsToList (what: allowed:
      lib.optional (!(lib.any (h: h == allowed) settings.allow.hosts)) "${host}'s gate stops the house's ${what} behind cloudflare") houseHosts)
    ++ lib.optional (settings.session == null) "${host}'s gate cannot tell a logged-in user"
  ) ingresses);

  "as the route opts in" = lib.concatLists (lib.mapAttrsToList (name: r: lib.concatLists (lib.mapAttrsToList (router: rendered: let
    flags = gateFlags edge rendered;
    gated = lib.elem "crowdsec" r.on;
    says = feature: if lib.elem feature r.on then "on" else "off";
  in
    if flags == null then lib.optional gated "vm-200 router ${router} has no gate, its route takes crowdsec"
    else lib.optional (!gated) "vm-200 router ${router} has a gate, its route takes no crowdsec"
    ++ lib.concatLists (lib.mapAttrsToList (flag: feature:
      lib.optional ((flags.${flag} or "0") != (if lib.elem feature r.on then "1" else "0"))
        "vm-200 router ${router}: the gate's ${flag} is ${flags.${flag} or "absent"}, its route's ${feature} says ${says feature}"
    ) features)
  ) (edgeRoutersOf name))) edgeRoutes);

  # the owner's rule: an onion visitor is always asked, whatever its route's features say
  "onion captcha" = lib.concatLists (lib.mapAttrsToList (name: router: let flags = gateFlags edge router; in
    if flags == null then [ "vm-200 onion router ${name} has no gate" ]
    else lib.optional ((flags.captcha or "0") != "1") "vm-200 onion router ${name}: the gate's captcha is ${flags.captcha or "absent"}"
  ) onionRouters)
    ++ map (address: "vm-200's gate does not know the onion address ${address}")
      (lib.subtractLists (lib.attrValues ((gateOf edge).captcha.onions or { })) onionAddresses);

  # a search crawler reads an indexable route's own robots.txt and passes anubis' and crowdsec's checks of its ranges
  # and reverse dns; everywhere else it reads the lab's disallow-all
  "indexable" = map (h: "vm-200 answers ${net.fqdn h}'s robots.txt with the lab's disallow-all, its route is indexable")
      (lib.filter (h: !(robotsSpared h)) indexableHosts)
    ++ map (h: "vm-200 leaves ${net.fqdn h}'s robots.txt to its backend, no route of it is indexable")
      (lib.filter robotsSpared robotsCovered)
    ++ lib.optionals (indexableHosts != [ ]) (
      lib.optional (edge.services.anubis.instances.ingress.botPolicy != null)
        "vm-200's anubis has a policy of its own, its bundled one admits the verified search crawlers"
      ++ lib.optional (!(lib.elem "crowdsecurity/whitelist-good-actors" crowdsecCollections))
        "vm-200's crowdsec may ban search crawlers: crowdsecurity/whitelist-good-actors is not installed");

  "captcha" = lib.optional ((gateOf edge).captcha == null) "vm-200, the internet's ingress, asks no captcha"
    ++ lib.concatLists (lib.mapAttrsToList (host: config:
      lib.optional (((gateOf config).captcha.answerLog or null) != null) "${host} logs every captcha's answer (a vm test's hook)"
    ) configs);
})
