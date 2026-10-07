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

  # the defences every public request passes, in order; `cloudflare-only` may sit after the strip. Each limit runs
  # per client, then per route (one route's budget over all its clients, modules/limits `route`). The body limit
  # buffers before the retry: a retry inside it would resend a consumed body, empty
  chainLaw = host: config: lib.concatLists (lib.mapAttrsToList (name: r:
    let
      m = r.middlewares or [ ];
      # padded, so a short chain fails the comparison instead of the evaluation
      padded = m ++ lib.genList (_: "") 10;
      rest = lib.drop (if lib.elemAt padded 2 == "cloudflare-only" then 3 else 2) padded;
      limits = [ "rate-limit" "route-rate-limit" "inflight-limit" "route-inflight-limit" ];
      afterLimits = lib.drop (lib.length limits + 1) rest;
      afterBody = if lib.hasPrefix "body-limit-" (lib.head afterLimits) then lib.tail afterLimits else afterLimits;
    in
    lib.optional (lib.take 2 m != [ "client-ip" "strip-client-headers" ]
      || !(lib.hasPrefix "crowdsec" (lib.head rest))
      || lib.take (lib.length limits) (lib.tail rest) != limits
      || lib.head afterBody != "retry-upstream"
      || !(lib.hasPrefix "secure-headers" (lib.elemAt afterBody 1)))
      "${host} router ${name}: chain ${toString m} is not client-ip, strip-client-headers, [cloudflare-only], crowdsec*, ${toString limits}, [body-limit-*], retry-upstream, secure-headers*"
  ) (websecure config));

  ssoRoutes = lib.filterAttrs (_: r: r.off.sso == null) catalog.internal;
  autheliaRules = authelia.services.authelia.instances.main.settings.access_control.rules;
  ruleIndex = host: policy: lib.lists.findFirstIndex (r: r.domain == [ (net.fqdn host) ] && r.policy == policy) null autheliaRules;

  appsSubnet = net.zones.apps.subnet;
  refusal = "!ClientIP(`${appsSubnet}`)";
  routerRules = router.networking.firewall.extraForwardRules;
  lines = text: lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (map lib.trim (lib.splitString "\n" text));
  forwardLines = lines routerRules;
  natAccept = lib.lists.findFirstIndex (l: lib.hasInfix "oifname \"${net.wan.interface}\" accept" l && lib.hasInfix "comment" l) null forwardLines;
  lastDrop = lib.foldl' (acc: i: if lib.hasInfix " drop" (lib.elemAt forwardLines i) then i else acc) (-1)
    (lib.range 0 (lib.length forwardLines - 1));

  transports = config: (httpOf config).serversTransports or { };
  relays = lib.filterAttrs (_: r: lib.hasSuffix "-relay" r.service) (websecure edge);

  metricsBlocks = lib.filterAttrs (name: _: lib.hasSuffix "-metrics-block" name) (httpOf edge).routers;
  appRouters = lib.filterAttrs (name: r: r ? service && lib.elem "websecure" (r.entryPoints or [ ]) && (r.priority or 0) < 1000
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

  # the apps zone may pull images and use nothing else on the internal ingress, robots.txt included
  "apps zone" = lib.concatLists (lib.mapAttrsToList (name: r: let
    admitted = map (m: lib.head (lib.splitString "/" (lib.head m))) (lib.filter lib.isList (builtins.split "ClientIP\\(`([^`]+)`\\)" r.rule));
    onlyOthers = admitted != [ ] && !(lib.any (ip: net.cidrContains net.zones.apps.subnet ip) admitted);
  in
    lib.optional (name != "registry-api-tls" && !(lib.hasInfix refusal r.rule) && !onlyOthers) "vm-100 router ${name} answers the apps zone"
  ) (websecure internalIngress))
  ++ (let pull = (websecure internalIngress).registry-api-tls; in
    lib.optional (lib.hasInfix "Method(`PUT`)" pull.rule || lib.hasInfix "Method(`POST`)" pull.rule || lib.hasInfix "Method(`DELETE`)" pull.rule)
      "registry-api-tls allows more than GET and HEAD"
    ++ lib.optional (!(lib.any (m: lib.hasSuffix "-auth" m) pull.middlewares)) "registry-api-tls pulls without a credential")
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

  # a route kept off the internet answers no dmz neighbour through the edge
  "internal only" = map (range: "vm-200 internal-only admits ${range}, which overlaps a dmz")
    (lib.filter (range: lib.any (z: cidr.overlaps range net.zones.${z}.subnet) [ "external" "apps" ])
      (httpOf edge).middlewares.internal-only.ipAllowList.sourceRange);

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
  ) (lib.filterAttrs (_: r: r.vmid != null && r.off.sso == null) catalog.internal));
}
