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
    ++ lib.optional (!(lib.elem (net.fqdn net.wan.publicHost) settings.allow.hosts)) "${host}'s gate stops the house behind cloudflare"
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

  "captcha" = lib.optional ((gateOf edge).captcha == null) "vm-200, the internet's ingress, asks no captcha"
    ++ lib.concatLists (lib.mapAttrsToList (host: config:
      lib.optional (((gateOf config).captcha.answerLog or null) != null) "${host} logs every captcha's answer (a vm test's hook)"
    ) configs);
})
