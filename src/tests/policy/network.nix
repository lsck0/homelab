# the network and ingress laws, over the evaluated configurations (tests/policy-eval.nix)
#
# Each law is stated as the policy, read off the rendered configuration, never recomputed the way the module
# computes it: a chain in the order the defences must run, a rule the router must contain before another, an
# address the dmz must never be trusted with.
{ lib, configs, lab, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  cidr = import ../../modules/cidr.nix { inherit lib; };
  internalIngress = configs."100-internal-traefik";
  edge = configs."200-external-traefik";
  authelia = configs."101-internal-authelia";
  router = configs."300-router";

  httpOf = config: config.services.traefik.dynamicConfigOptions.http;
  websecure = config: lib.filterAttrs (_: r: lib.elem "websecure" (r.entryPoints or [ ])) (httpOf config).routers;
  lawsOf = laws: lib.concatLists (lib.mapAttrsToList (name: law: map (v: "${name}: ${v}") law) laws);

  # the defences a request passes, in this order, each where its route opts in: `cloudflare-only` on the socket peer,
  # the real client and the strip of its identity headers on every router. The gate answers crowdsec's decisions
  # before the waf spends anything on a banned client. Each limit runs per client, then per route (one route's budget
  # over all its clients, modules/limits `route`). The body limit buffers before the retry: a retry inside it would
  # resend a consumed body, empty. The router's own middlewares (sso, its headers) come last
  chainOrder = [
    "cloudflare-only" "client-ip" "strip-client-headers" "gate" "crowdsec" "rate-limit" "route-rate-limit" "inflight-limit"
    "route-inflight-limit" "body-limit" "retry-upstream" "secure-headers"
  ];
  # the entries of chainOrder named with a suffix: gate-<flags>, body-limit-<bytes>, secure-headers-<variant>
  chainFamilies = [ "gate" "body-limit" "secure-headers" ];
  # a middleware's entry of chainOrder (a limitScale's <limit>-x<scale> its limit's), null for a router's own
  chainEntryOf = name: let unscaled = let s = builtins.match "(.*)-x[0-9]+" name; in if s == null then name else lib.head s; in
    lib.findFirst (e: unscaled == e || (lib.elem e chainFamilies && lib.hasPrefix "${e}-" name)) null chainOrder;
  chainRankOf = name: let e = chainEntryOf name; in
    if e == null then lib.length chainOrder else lib.lists.findFirstIndex (x: x == e) null chainOrder;
  chainLawOf = host: routers: lib.concatLists (lib.mapAttrsToList (name: r:
    let
      m = r.middlewares or [ ];
      ranks = map chainRankOf m;
      has = entry: lib.any (n: chainEntryOf n == entry) m;
    in
    lib.optional (ranks != lib.sort lib.lessThan ranks || !(has "client-ip") || !(has "strip-client-headers") || !(has "retry-upstream"))
      "${host} router ${name}: chain ${toString m} is not in the order ${toString chainOrder}, client-ip, strip-client-headers and retry-upstream on every router"
    ++ lib.optional (has "crowdsec" && !(has "gate")) "${host} router ${name}: the waf runs without the gate in front"
    ++ lib.optional (has "rate-limit" != has "route-rate-limit" || has "inflight-limit" != has "route-inflight-limit")
      "${host} router ${name}: a limit runs per client or per route alone"
  ) routers);
  chainLaw = host: config: chainLawOf host (websecure config);

  ssoRoutes = lib.filterAttrs (_: r: lib.elem "sso" r.on) catalog.internal;
  autheliaRules = authelia.services.authelia.instances.main.settings.access_control.rules;
  ruleIndex = host: policy: lib.lists.findFirstIndex (r: r.domain == [ (net.fqdn host) ] && r.policy == policy) null autheliaRules;

  # a route's ssoPaths: on its ingress, a router with authelia matches each by the lab's one pattern and outranks
  # every router of the host without authelia but the probes'; authelia's first rule for host and path is a two_factor
  # one, a deny of the same after it. A rule naming other paths is taken as not matching this one
  service = import ../../modules/service.nix { inherit lib; };
  # the probes' rank (modules/traefik probePriority): their health path alone passes by authelia
  probeRank = 1000;
  rankOf = r: r.priority or (lib.stringLength r.rule);
  ingressOf = r: if r.zone == "internal" then internalIngress else edge;
  pathLaw = name: r: path: let
    host = net.fqdn r.host;
    pattern = service.prefixPattern path;
    routers = lib.filterAttrs (_: x: lib.hasInfix "Host(`${host}`)" x.rule) (websecure (ingressOf r));
    gated = lib.filterAttrs (_: x: lib.elem "authelia" (x.middlewares or [ ]) && lib.hasInfix "PathRegexp(`${pattern}`)" x.rule) routers;
    open = lib.filterAttrs (_: x: !(lib.elem "authelia" (x.middlewares or [ ])) && rankOf x < probeRank) routers;
    lowest = lib.foldl' lib.min probeRank (map rankOf (lib.attrValues gated));
    applies = rule: (lib.elem host rule.domain || lib.elem "*.${net.domain}" rule.domain) && (!(rule ? resources) || lib.elem pattern rule.resources);
    first = lib.lists.findFirstIndex applies null autheliaRules;
    firstRule = if first == null then { policy = null; } else lib.elemAt autheliaRules first;
    denyAfter = first != null && lib.any (rule: applies rule && rule ? resources && rule.policy == "deny") (lib.drop first autheliaRules);
  in
    lib.optional (gated == { }) "route ${name}: no router with authelia matches ${host}${path}"
    ++ map (n: "route ${name}: router ${n} outranks the authelia router of ${host}${path}") (lib.attrNames (lib.filterAttrs (_: x: rankOf x >= lowest) open))
    ++ lib.optional (firstRule.policy != "two_factor" || !(firstRule ? resources) || !denyAfter)
      "authelia: ${host}${path} needs its own two_factor rule ahead of every other rule for it, followed by a deny";
  pathRoutes = lib.filterAttrs (_: r: r.ssoPaths != [ ]) (catalog.internal // catalog.external);

  # the collector reads every exporter at its own port, never through an ingress's web ports, where ssoPaths bite
  collectorConfig = configs.${inventory.${toString lab.roles.collector}.name};
  scrapeTargets = lib.concatMap (job: lib.concatMap (c: c.targets or [ ]) (job.static_configs or [ ])) collectorConfig.services.prometheus.scrapeConfigs;
  ingressDoors = lib.concatMap (z: map (port: "${net.ipOf z.ingress}:${toString port}") [ net.ports.http net.ports.https ])
    (lib.filter (z: z.ingress != null) (lib.attrValues net.zones));

  appsSubnet = net.zones.apps.subnet;
  refusal = "!ClientIP(`${appsSubnet}`)";
  # the image pull route's router and its parts (a websocket's, modules/traefik)
  pulls = name: name == "registry-api-tls" || lib.hasPrefix "registry-api-tls-" name;
  routerRules = router.networking.firewall.extraForwardRules;
  lines = text: lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim (lib.splitString "\n" text));
  forwardLines = lines routerRules;
  natAccept = lib.lists.findFirstIndex (l: lib.hasInfix "oifname \"${net.wan.interface}\" accept" l && lib.hasInfix "comment" l) null forwardLines;
  lastDrop = lib.foldl' (acc: i: if lib.hasInfix " drop" (lib.elemAt forwardLines i) then i else acc) (-1)
    (lib.range 0 (lib.length forwardLines - 1));

  transports = config: (httpOf config).serversTransports or { };
  relays = lib.filterAttrs (_: r: lib.hasSuffix "-relay" r.service) (websecure edge);

  metricsBlocks = lib.filterAttrs (name: _: lib.hasSuffix "-metrics-block" name) (httpOf edge).routers;
  appRouters = lib.filterAttrs (name: r: r ? service && lib.elem "websecure" (r.entryPoints or [ ]) && (r.priority or 0) < probeRank
    && lib.any (a: lib.hasPrefix "${a}-" name || name == "${a}-tls") (lib.attrNames catalog.apps)) (httpOf edge).routers;

  # the methods a rule admits: those of a top-level method-only conjunct; null (any) without one or with a top-level ||
  depthOf = text: (lib.foldl' (s: c:
    if c == "`" then s // { quoted = !s.quoted; }
    else if s.quoted then s
    else if c == "(" then s // { depth = s.depth + 1; }
    else if c == ")" then s // { depth = s.depth - 1; }
    else s) { depth = 0; quoted = false; } (lib.stringToCharacters text));
  balanced = text: depthOf text == { depth = 0; quoted = false; };
  topLevel = separator: text: lib.foldl' (acc: piece:
    if acc.open == "" then (if balanced piece then acc // { parts = acc.parts ++ [ piece ]; } else acc // { open = piece; })
    else let joined = acc.open + separator + piece; in
      if balanced joined then { parts = acc.parts ++ [ joined ]; open = ""; } else acc // { open = joined; })
    { parts = [ ]; open = ""; } (lib.splitString separator text);
  methodClause = builtins.match "\\(?(Method\\(`[A-Z]+`\\)( \\|\\| Method\\(`[A-Z]+`\\))*)\\)?";
  admittedMethods = rule: let
    conjuncts = (topLevel " && " rule).parts;
    clauses = lib.filter (c: methodClause c != null) conjuncts;
  in
    if lib.any (c: lib.length (topLevel " || " c).parts > 1) conjuncts || clauses == [ ] then null
    else map lib.head (lib.filter lib.isList (builtins.split "Method\\(`([A-Z]+)`\\)" (lib.head clauses)));
  buffering = config: lib.attrNames (lib.filterAttrs (_: m: m ? buffering) (httpOf config).middlewares);

  portForwardLines = lines router.networking.nftables.tables.port-forwards.content;

  # a connection from one guest to another's port passes the router (same zone, a trusted network, or an accept of the
  # three) and the target's guard (an unguarded port, or a trusted or granted source)
  inSet = ip: text: lib.any (e: if lib.hasInfix "/" e then cidr.contains e ip else e == ip) (map lib.trim (lib.splitString "," text));
  forwardAccepts = lib.filter (m: m != null) (map (builtins.match
    "iifname \"([^\"]+)\" ip saddr \\{ ([^}]*) } ip daddr \\{ ([^}]*) } tcp dport \\{ ([^}]*) } accept") forwardLines);
  routerPasses = from: to: port: let source = net.zoneOf from; in
    source.name == (net.zoneOf to).name
    || (lib.elem "iifname \"${source.interface}\" accept" forwardLines
      && !(lib.any (l: lib.hasPrefix "iifname \"${source.interface}\"" l && lib.hasSuffix " drop" l) forwardLines))
    || lib.any (m: lib.elemAt m 0 == source.interface && inSet (net.ipOf from) (lib.elemAt m 1)
      && inSet (net.ipOf to) (lib.elemAt m 2) && inSet (toString port) (lib.elemAt m 3)) forwardAccepts;
  configOf = id: lib.findFirst (c: c.homelab.vmid == id) (throw "no configuration has vmid ${id}") (lib.attrValues configs);
  guardAdmits = from: to: port: let guard = (configOf to).homelab.ingressOnly; in
    !(lib.elem port guard.ports) || lib.any (s: cidr.contains s (net.ipOf from)) (guard.trusted ++ guard.allowed.${toString port} or [ ]);
  reach = from: to: port: lib.optional (!(routerPasses from to port)) "the router drops vm-${from} -> vm-${to}:${toString port}"
    ++ lib.optional (!(guardAdmits from to port)) "vm-${to}'s guard drops vm-${from} on ${toString port}";
  running = id: inventory.${id}.powered;
  backendsOf = r: lib.filter running (if r.vmid != null then [ (toString r.vmid) ]
    else (lib.findFirst (c: c.apps ? ${r.app}) null (lib.attrValues catalog.clusters)).workerIds);

  # an egress member's rule over every destination outside the private ranges: `ip saddr { members }<through> ip
  # daddr != { private ranges } <action>`, through naming the interface it is restricted to, empty for none
  egressRules = lib.filter (m: m != null) (map (builtins.match "ip saddr \\{ ([^}]*) }(.*) ip daddr != \\{ ([^}]*) } (.*)")
    (lines (router.networking.nftables.tables.egress.content or "")));
  internetOnly = text: lib.sort lib.lessThan (map lib.trim (lib.splitString "," text)) == lib.sort lib.lessThan net.privateRanges;
  egressRule = ip: through: action: lib.any (m: inSet ip (lib.elemAt m 0) && lib.elemAt m 1 == through
    && internetOnly (lib.elemAt m 2) && builtins.match action (lib.elemAt m 3) != null) egressRules;
  torListeners = name: map (l: if lib.isAttrs l then l else { port = l; }) (lib.toList router.services.tor.settings.${name});
  torTransPorts = lib.concatMapStringsSep "|" (l: toString l.port) (torListeners "TransPort");
  torDnsPorts = map (l: "${l.addr}:${toString l.port}") (torListeners "DNSPort");
  # where coredns sends a client's names: the forward of the server block whose view names its address
  resolverOf = ip: let
    block = lib.findFirst (b: lib.hasInfix "'${ip}/32'" b) "" (lib.splitString ".:53 {" router.services.coredns.config);
    forwards = lib.filter (lib.hasPrefix "forward . ") (map lib.trim (lib.splitString "\n" block));
  in if forwards == [ ] then null else lib.elemAt (lib.splitString " " (lib.head forwards)) 2;

  # an onion route's address: served on the edge's onion entrypoint (the one at tor's onionIngress port) alone
  torPorts = import ../../modules/tor-ports.nix;
  serves = host: r: lib.hasInfix "Host(`${host}`)" (r.rule or "");
  onionEntryPoints = lib.attrNames (lib.filterAttrs (_: e: e.address or "" == ":${toString torPorts.onionIngress}")
    edge.services.traefik.staticConfigOptions.entryPoints);
  onionLaw = name: r: let
    address = r.onionAddress;
    onionRouters = lib.filterAttrs (_: x: serves address x) (httpOf edge).routers;
    nameServices = lib.unique (map (x: x.service) (lib.attrValues (lib.filterAttrs (_: x: serves (net.fqdn r.host) x) (websecure edge))));
    published = map (m: { inherit (m) port; target = { inherit (m.target) addr port; }; })
      (router.services.tor.relay.onionServices.${name} or { map = [ ]; }).map;
  in
    if address == null then [ "${name}: onion without an address in src/generated/onions.json (src/scripts/secrets-sync.sh --apply --generate-guarded)" ]
    else lib.optional (onionRouters == { }) "${name}: vm-200 serves its onion address with no router"
    ++ lib.mapAttrsToList (n: _: "${name}: vm-200 router ${n} serves its onion address beside the onion entrypoint")
      (lib.filterAttrs (_: x: x.entryPoints or [ ] != onionEntryPoints && x.entryPoints or [ ] != [ "anubis-balancer" ]) onionRouters)
    ++ lib.mapAttrsToList (n: x: "${name}: vm-200 router ${n} sends its onion visitors to ${x.service}, which its name's routers do not use")
      (lib.filterAttrs (_: x: !(lib.elem x.service nameServices)) onionRouters)
    ++ chainLawOf "vm-200" (lib.filterAttrs (_: x: x.entryPoints or [ ] == onionEntryPoints) onionRouters)
    ++ lib.mapAttrsToList (host: _: "${name}: ${host} serves its onion address")
      (lib.filterAttrs (_: config: lib.any (serves address) (lib.attrValues (httpOf config).routers)) { vm-100 = internalIngress; })
    ++ lib.optional (published != [ { port = net.ports.http; target = { addr = net.ipOf net.zones.external.ingress; port = torPorts.onionIngress; }; } ])
      "${name}: the router's tor does not publish it to the edge's onion entrypoint";

  # a guest's direct calls: every <address>:<port> its units, containers and /etc are configured with, and every
  # <NAME>_HOST and <NAME>_PORT pair of one environment. A template a unit reads from the store stays unread here
  guestIds = lib.filter (id: id != null) (map (c: c.homelab.vmid) (lib.attrValues configs));
  guestOfIp = lib.listToAttrs (map (id: lib.nameValuePair (net.ipOf id) id) guestIds);
  addressPattern = "([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+):([0-9]+)";
  addressesIn = text: map (m: { ip = lib.elemAt m 0; port = lib.toInt (lib.elemAt m 1); })
    (lib.filter lib.isList (builtins.split addressPattern text));
  hostPortPairsIn = env: lib.concatMap (key: let port = env."${lib.removeSuffix "_HOST" key}_PORT" or null; in
    lib.optional (lib.hasSuffix "_HOST" key && port != null) { ip = toString env.${key}; port = lib.toInt (toString port); })
    (lib.attrNames env);
  environmentsOf = config: map (s: s.environment) (lib.attrValues config.systemd.services)
    ++ map (c: c.environment) (lib.attrValues config.virtualisation.oci-containers.containers);
  textsOf = config: lib.concatMap (s: [ s.script s.preStart s.postStart ]) (lib.attrValues config.systemd.services)
    ++ map (e: if e.text == null then "" else e.text) (lib.attrValues config.environment.etc)
    ++ lib.concatMap (env: map toString (lib.attrValues env)) (environmentsOf config);
  callsOf = config: lib.unique (lib.concatMap addressesIn (textsOf config) ++ lib.concatMap hostPortPairsIn (environmentsOf config));
  directCallLaw = config: let from = config.homelab.vmid; in lib.concatMap (call: let to = guestOfIp.${call.ip}; in
    lib.optionals (to != from && running to) (reach from to call.port))
    (lib.filter (call: guestOfIp ? ${call.ip}) (callsOf config));

  # a route's routers without its limits answer the house alone: its lan, wireguard and the internal zone, by socket
  # peer; never a dmz, the apps zone or an address of the internet
  houseNetworks = [ net.wan.subnet net.wireguard.subnet net.zones.internal.subnet ];
  admittedRanges = rule: map lib.head (lib.filter lib.isList (builtins.split "ClientIP\\(`([^`]+)`\\)" rule));
  # a ClientIP range inside one network: its first address in it, no wider than it (a bare address is a /32)
  within = network: range: let prefix = if lib.hasInfix "/" range then cidr.prefix range else 32; in
    cidr.contains network (lib.head (lib.splitString "/" range)) && prefix >= cidr.prefix network;
  houseLaw = host: config: lib.concatLists (lib.mapAttrsToList (name: r: let ranges = admittedRanges r.rule; in
    lib.optional (ranges == [ ] || lib.any (range: !(lib.any (house: within house range) houseNetworks)) ranges)
      "${host} router ${name} answers more than the house without its limits: ${toString ranges}"
  ) (lib.filterAttrs (name: _: lib.hasSuffix "-house" name) (websecure config)));

  kea = router.services.kea.dhcp4.settings.subnet4;
  inPool = ip: pool: let bounds = map lib.trim (lib.splitString "-" pool.pool);
    toInt = a: lib.foldl' (acc: o: acc * 256 + lib.toInt o) 0 (lib.splitString "." a); in
    toInt ip >= toInt (lib.head bounds) && toInt ip <= toInt (lib.last bounds);
in
lawsOf {
  "defence chain" = chainLaw "vm-100" internalIngress ++ chainLaw "vm-200" edge;

  "sso routes" = lib.concatLists (lib.mapAttrsToList (name: r:
    lib.optional (!(lib.elem "authelia" ((websecure internalIngress)."${name}-tls".middlewares or [ ])))
      "vm-100 router ${name}-tls lacks authelia"
    ++ lib.optional (ruleIndex r.host "two_factor" == null || ruleIndex r.host "deny" == null
      || ruleIndex r.host "deny" < ruleIndex r.host "two_factor")
      "authelia: ${r.host} needs a two_factor rule followed by a deny"
  ) ssoRoutes);

  "sso paths" = lib.concatLists (lib.mapAttrsToList (name: r: lib.concatMap (pathLaw name r) r.ssoPaths) pathRoutes);

  "direct scrapes" = map (t: "the collector scrapes ${t}, an ingress's web port") (lib.intersectLists ingressDoors scrapeTargets);

  # the apps zone may pull images and use nothing else on the internal ingress, robots.txt included
  "apps zone" = lib.concatLists (lib.mapAttrsToList (name: r: let
    admitted = map (m: lib.head (lib.splitString "/" (lib.head m))) (lib.filter lib.isList (builtins.split "ClientIP\\(`([^`]+)`\\)" r.rule));
    onlyOthers = admitted != [ ] && !(lib.any (ip: net.cidrContains net.zones.apps.subnet ip) admitted);
  in
    lib.optional (!(pulls name) && !(lib.hasInfix refusal r.rule) && !onlyOthers) "vm-100 router ${name} answers the apps zone"
  ) (websecure internalIngress))
  ++ lib.concatLists (lib.mapAttrsToList (name: pull:
    lib.optional (lib.hasInfix "Method(`PUT`)" pull.rule || lib.hasInfix "Method(`POST`)" pull.rule || lib.hasInfix "Method(`DELETE`)" pull.rule)
      "${name} allows more than GET and HEAD"
    ++ lib.optional (!(lib.any (m: lib.hasSuffix "-auth" m) pull.middlewares)) "${name} pulls without a credential"
  ) (lib.filterAttrs (name: _: pulls name) (websecure internalIngress)))
  ++ lib.optional (lib.hasInfix "DELETE" (websecure internalIngress).registry-push-tls.rule) "registry pushers may DELETE";

  # nothing between the ingresses or toward proxmox travels unverified
  "tls verification" = lib.concatLists (lib.mapAttrsToList (host: config: lib.mapAttrsToList (name: _:
    "${host} transport ${name} skips verification") (lib.filterAttrs (_: t: t.insecureSkipVerify or false) (transports config)))
    { vm-100 = internalIngress; vm-200 = edge; })
  ++ lib.concatLists (lib.mapAttrsToList (name: r: let t = (transports edge).${r.service} or null; host = lib.head (builtins.match ".*Host\\(`([^`]+)`\\).*" r.rule); in
    lib.optional (t == null || t.serverName or null != host) "vm-200 relay ${name} does not verify the internal ingress as ${host}") relays);

  # a buffering middleware spools whole responses to disk: no download passes one
  "buffered downloads" = lib.concatLists (lib.mapAttrsToList (host: config: lib.concatLists (lib.mapAttrsToList (name: r: let
      methods = admittedMethods r.rule;
    in
    lib.optional (lib.intersectLists (buffering config) (r.middlewares or [ ]) != [ ]
      && (methods == null || lib.elem "GET" methods || lib.elem "HEAD" methods))
      "${host} router ${name} admits GET or HEAD behind a buffering middleware"
  ) (websecure config))) { vm-100 = internalIngress; vm-200 = edge; });

  # an ingress reaches every running backend of its routes; a cluster's controller every one of its wakers
  "reach" = lib.concatMap (r: lib.concatMap (b: reach net.zones.${r.zone}.ingress b r.port) (backendsOf r))
    (lib.attrValues (catalog.internal // catalog.external))
  ++ lib.concatLists (lib.mapAttrsToList (_: c:
    lib.concatMap (w: reach w c.managerId catalog.swarm.controllerPort) (lib.filter running c.wakers)) catalog.clusters);

  # a guest calls another guest's port only where the router passes it and the target's guard admits it (a grant)
  "direct calls" = lib.concatMap directCallLaw (lib.filter (c: c.homelab.vmid != null) (lib.attrValues configs));

  # a route kept off the internet answers no dmz neighbour through the edge
  "internal only" = map (range: "vm-200 internal-only admits ${range}, which overlaps a dmz")
    (lib.filter (range: lib.any (z: cidr.overlaps range net.zones.${z}.subnet) [ "external" "apps" ])
      (httpOf edge).middlewares.internal-only.ipAllowList.sourceRange);

  # what a houseUnlimited route spares the house it spares nobody else
  "house routers" = houseLaw "vm-100" internalIngress ++ houseLaw "vm-200" edge;

  # an unknown name gets a 404 at the edge, nothing travels inward for it
  "no catch-all" = lib.mapAttrsToList (name: _: "vm-200 router ${name} matches any host")
    (lib.filterAttrs (_: r: lib.hasInfix "HostRegexp" (r.rule or "")) (httpOf edge).routers);

  # the client the limits and the bouncer act on is one and the same
  "client identity" = lib.concatLists (lib.mapAttrsToList (host: config: let h = httpOf config; in
    lib.optional (h.middlewares.client-ip.plugin.client-ip.trustedIPs != h.middlewares.crowdsec.plugin.crowdsec-bouncer.forwardedHeadersTrustedIPs)
      "${host}: client-ip and the bouncer trust different hops"
    ++ lib.optional (h.middlewares.rate-limit.rateLimit.sourceCriterion != { requestHeaderName = "X-Real-Ip"; })
      "${host}: the rate limit is not keyed on the client client-ip names"
    ++ lib.optional (lib.any (cidr: lib.elem cidr net.privateRanges) h.middlewares.client-ip.plugin.client-ip.trustedIPs)
      "${host}: a private range's forwarded headers are believed")
    { vm-100 = internalIngress; vm-200 = edge; })
  ++ lib.optional (edge.services.traefik.staticConfigOptions.entryPoints.websecure.forwardedHeaders.trustedIPs != net.cloudflareRanges)
    "vm-200 believes forwarded headers from more than cloudflare";

  "metrics blocks" = lib.concatLists (lib.mapAttrsToList (name: b:
    lib.optional (!(lib.hasInfix "(?i)" b.rule)) "vm-200 ${name} is case-sensitive"
    ++ lib.mapAttrsToList (app: _: "vm-200 ${name} does not outrank ${app}")
      (lib.filterAttrs (_: r: (r.priority or 0) >= b.priority) appRouters)
  ) metricsBlocks);

  # the router's drops come before nixos nat's blanket accept toward the wan
  "router order" = lib.optional (natAccept == null) "the nat module's accept is missing from the forward rules"
    ++ lib.optional (natAccept != null && natAccept < lastDrop) "a drop of the router's forward policy comes after nat's accept";

  # an onion route is served by the edge alone, with its chain and its name's backend, and published to it by tor
  "onion" = lib.concatLists (lib.mapAttrsToList onionLaw (lib.filterAttrs (_: r: r.onion) catalog.external));

  # an egress member's internet traffic leaves through its exit or not at all: a vpn member's never through the
  # house, a tor member's through no interface, its tcp into tor's TransPort and its names to tor's DNSPort
  "egress killswitch" = lib.concatLists (lib.mapAttrsToList (id: e: let ip = net.ipOf id; in
    if e.via == "vpn" then lib.optional (!(egressRule ip " oifname \"${net.wan.interface}\"" "counter drop"))
      "vm-${id} (vpn) may leave through the house: no drop of its internet traffic toward the wan"
    else lib.optional (!(egressRule ip "" "counter drop"))
      "vm-${id} (tor) has a direct internet path: no drop of its internet traffic through every interface"
    ++ lib.optional (!(egressRule ip "" "meta l4proto tcp (counter )?redirect to :(${torTransPorts})"))
      "vm-${id} (tor): its internet tcp is not redirected into tor's TransPort"
    ++ lib.optional (!(lib.elem (resolverOf ip) torDnsPorts))
      "vm-${id} (tor): its names are not resolved by tor's DNSPort"
  ) lab.egress);

  # the router's rendered lease pools, against every static address
  "inventory" = lib.concatLists (lib.mapAttrsToList (id: v:
    lib.optional (v.type != "router" && lib.any (s: lib.any (inPool v.ip) s.pools) kea) "${id}: ${v.ip} lies in a dhcp pool"
  ) inventory);

  # the house's public address forwards a named port only: a lab-only route has none
  "port forwards" = map (l: "the router forwards no port: ${l}")
    (lib.filter (l: lib.hasInfix " dport " l && builtins.match ".* dport [0-9]+ .*" l == null) portForwardLines);

  # no guest trusts the homepage, the prober or the agent with every guarded port; each trusts its own address
  "ingress guards" = lib.concatLists (lib.mapAttrsToList (name: config:
    map (s: "${name} trusts ${s} on every guarded port") (lib.intersectLists config.homelab.ingressOnly.trusted
      (map net.hostSource (lib.remove config.homelab.vmid (with lab.roles; [ dashboard collector operator ]))))
  ) configs);

  # the prober and the status dots check an sso route through its ingress: a grant onto the backend passes authelia.
  # Only a dashboard widget without a url of its own queries the backend, with the token it holds
  "probes through the ingress" = lib.concatLists (lib.mapAttrsToList (name: r: let
    admitted = configs.${inventory.${toString r.vmid}.name}.homelab.ingressOnly.allowed.${toString r.port} or [ ];
    queried = lib.any (c: c.route == name && c.widget != null && c.widget.url == null) lab.homepage;
  in
    lib.optional (lib.elem (net.hostSource lab.roles.collector) admitted)
      "${name}: the prober reaches port ${toString r.port} past the ingress"
    ++ lib.optional (lib.elem (net.hostSource lab.roles.dashboard) admitted && !queried)
      "${name}: the dashboard reaches port ${toString r.port} past the ingress, with no widget querying it"
  ) (lib.filterAttrs (_: r: r.vmid != null && lib.elem "sso" r.on) catalog.internal));
}
