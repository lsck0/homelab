# the anti-bot laws, over the ingresses' rendered gate (modules/traefik lib/gate) and its middlewares
#
# Never hit: the house, wireguard, the internal zone and the ingress itself pass every gate untouched, as crowdsec
# never decides against them; a logged-in user is asked about. As the route opts in: a route taking crowdsec has the
# gate, which asks the captcha, limits anonymous clients, holds banned ones and sends forged search crawlers to the
# deception where the route takes each (its bot defence the last), read off the forwardauth address of its router.
# Onion captcha: every router on the onion entrypoint asks the captcha, no route can say otherwise, and the gate knows
# every onion address it guards. Deception: every gate is wrapped by the errors middlewares that turn its deception
# statuses, and only those, into the gate's deception; crowdsec deceives scanners for a while and always bans them
# after, never deceives brute force, and bans nothing a browser or a shared address trips for a day on its first alert;
# the gate calls no crawler forged on a published list alone. No lab host logs the captcha's answers.
{
  lib,
  configs,
  inventory,
  site,
  catalog,
  ...
}:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  cidr = import ../../modules/cidr.nix { inherit lib; };

  ingresses = {
    vm-100 = configs."100-internal-traefik";
    vm-200 = configs."200-external-traefik";
  };
  edge = ingresses.vm-200;
  httpOf = config: config.services.traefik.dynamicConfigOptions.http;
  gateOf = config: config.homelab.traefik.gate.settings;

  # the networks no defence may ever stop, each by an address inside it; the gate also passes the ingress's own calls
  neverHit = {
    "the house lan" = net.wan.subnet;
    "wireguard" = net.wireguard.subnet;
    "the internal zone" = net.zones.internal.subnet;
  };
  gateNeverHit = neverHit // {
    "the ingress itself" = "127.0.0.1/32";
  };
  # the house behind cloudflare by the names the router serves: its v4 address, every address of its v6 prefix
  houseHosts = {
    "v4 address" = {
      name = net.fqdn net.wan.publicHost;
      network = "ip4";
      bits = 32;
    };
    "v6 prefix" = {
      name = net.fqdn net.wan.publicPrefixHost;
      network = "ip6";
      bits = net.wan.publicPrefixLength;
    };
  };
  covered = ranges: network: lib.any (range: cidr.contains range (lib.head (lib.splitString "/" network))) ranges;

  # a router's gate: the gate-* middleware of its chain that asks the gate (beside the deception's around it)
  gateOfRouter =
    config: router:
    lib.findFirst (m: lib.hasPrefix "gate" m && (httpOf config).middlewares.${m} ? forwardAuth) null (
      router.middlewares or [ ]
    );
  # the gate's features in a router's chain: the query of its forwardauth address
  gateFlags =
    config: router:
    let
      middleware = gateOfRouter config router;
      address = (httpOf config).middlewares.${middleware}.forwardAuth.address or "";
      query = lib.last (lib.splitString "?" address);
      pairs = map (p: lib.splitString "=" p) (lib.splitString "&" query);
    in
    if middleware == null then null else lib.listToAttrs (map (p: lib.nameValuePair (lib.head p) (lib.last p)) pairs);

  # a route's own routers on the edge: its route router and its relay, either of which the edge has
  edgeRoutersOf =
    name:
    lib.filterAttrs (
      router: _:
      lib.elem router [
        "${name}-tls"
        "${name}-relay"
      ]
    ) (httpOf edge).routers;
  features = {
    captcha = "captcha";
    limit = "anonymousLimit";
    tarpit = "tarpit";
    crawlers = "botDefense";
  };

  # crowdsec durations as the ladder writes them, in seconds
  secondsPer = {
    s = 1;
    m = 60;
    h = 3600;
  };
  durationSeconds =
    duration:
    let
      parts = builtins.match "([0-9]+)([smh])" duration;
    in
    lib.toInt (lib.head parts) * secondsPer.${lib.last parts};
  # a brute-force scenario of the hub or the lab: crowdsecurity/ssh-bf, http-bf-wordpress_bf, http-generic-bf
  bruteForce = scenario: builtins.match ".*[/_-]bf([_-].*)?" scenario != null;
  # the scenarios a profile's filter names
  profileScenarios =
    profile:
    let
      list = builtins.match ".*GetScenario\\(\\) in (\\[[^]]*]).*" (lib.head profile.filters);
    in
    if list == null then [ ] else builtins.fromJSON (lib.head list);
  # what a browser or one person behind a shared address trips: broken links' 404s, a fetch of every link, an
  # assistant's fetches through the labyrinth, a burst past the limits, failed proofs and captchas
  browserTrippable = [
    "crowdsecurity/http-probing"
    "crowdsecurity/http-crawl-non_statics"
    "homelab/labyrinth"
    "homelab/rate-limited"
    "homelab/anubis-failed"
    "homelab/captcha-failed"
  ];
  # what one browser behind a shared address can trip that crowdsec still deceives: a user agent switcher naming a
  # search crawler, a request whose path or query ends in a sensitive file's suffix
  sharedAddressDeceived = [
    "homelab/forged-crawler"
    "crowdsecurity/http-sensitive-files"
  ];
  # whether a profile's count filter admits a client without earlier decisions
  admitsFirstAlert =
    profile:
    let
      count = builtins.match ".*GetDecisionsSinceCount\\(.*\\) (<=|==|>=) ([0-9]+).*" (lib.head profile.filters);
    in
    count == null || lib.head count == "<=" || lib.last count == "0";
  # the profile crowdsec decides a client's first alert of a scenario by: the first, in order, of the ip profiles
  # naming the scenario or none (the fallback) that admits it
  firstRungOf =
    profiles: scenario:
    lib.findFirst (
      p:
      let
        named = profileScenarios p;
      in
      lib.hasInfix "GetScope() == 'Ip'" (lib.head p.filters)
      && (named == [ ] || lib.elem scenario named)
      && admitsFirstAlert p
    ) null profiles;
  daySeconds = durationSeconds "24h";
  edgeRoutes = catalog.external // catalog.internal;

  # the edge's onion entrypoint (the one at tor's onionIngress port) and every router on it
  torPorts = import ../../modules/tor-ports.nix;
  onionEntryPoints = lib.attrNames (
    lib.filterAttrs (
      _: e: e.address or "" == ":${toString torPorts.onionIngress}"
    ) edge.services.traefik.staticConfigOptions.entryPoints
  );
  onionRouters = lib.filterAttrs (
    _: router: lib.any (e: lib.elem e onionEntryPoints) (router.entryPoints or [ ])
  ) (httpOf edge).routers;
  onionAddresses = lib.filter (address: address != null) (
    map (r: r.onionAddress or null) (lib.attrValues catalog.external)
  );

  # robots.txt: the lab's disallow-all on every defended host, the backend's own on an indexable route's
  robotsRule = (httpOf edge).routers.robots-tls.rule;
  edgeHttp = lib.filter (r: r.protocol == "http") (lib.attrValues catalog.external);
  hostsOf = pred: lib.unique (map (r: r.host) (lib.filter pred edgeHttp));
  robotsSpared = host: lib.hasInfix "!Host(`${net.fqdn host}`)" robotsRule;
  indexableHosts = hostsOf (r: r.indexable);
  robotsCovered = lib.subtractLists (hostsOf (r: r.indexable || !(lib.elem "botDefense" r.on))) (hostsOf (_: true));
  crowdsecCollections = lib.splitString " " (
    edge.virtualisation.oci-containers.containers.crowdsec.environment.COLLECTIONS or ""
  );
in
lib.concatLists (
  lib.mapAttrsToList (law: violations: map (v: "${law}: ${v}") violations) {
    "never hit" = lib.concatLists (
      lib.mapAttrsToList (
        host: config:
        let
          settings = gateOf config;
          whitelist = config.homelab.traefik.crowdsecBouncer.whitelistCidrs;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            what: network: lib.optional (!(covered settings.allow.cidrs network)) "${host}'s gate stops ${what} (${network})"
          ) gateNeverHit
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            what: network: lib.optional (!(covered whitelist network)) "${host}'s crowdsec may ban ${what} (${network})"
          ) neverHit
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            what: allowed:
            lib.optional (
              !(lib.any (h: h == allowed) settings.allow.hosts)
            ) "${host}'s gate stops the house's ${what} behind cloudflare"
          ) houseHosts
        )
        ++ lib.optional (settings.session == null) "${host}'s gate cannot tell a logged-in user"
      ) ingresses
    );

    "as the route opts in" = lib.concatLists (
      lib.mapAttrsToList (
        name: r:
        lib.concatLists (
          lib.mapAttrsToList (
            router: rendered:
            let
              flags = gateFlags edge rendered;
              gated = lib.elem "crowdsec" r.on;
              says = feature: if lib.elem feature r.on then "on" else "off";
            in
            if flags == null then
              lib.optional gated "vm-200 router ${router} has no gate, its route takes crowdsec"
            else
              lib.optional (!gated) "vm-200 router ${router} has a gate, its route takes no crowdsec"
              ++ lib.concatLists (
                lib.mapAttrsToList (
                  flag: feature:
                  lib.optional ((flags.${flag} or "0") != (if lib.elem feature r.on then "1" else "0"))
                    "vm-200 router ${router}: the gate's ${flag} is ${flags.${flag} or "absent"}, its route's ${feature} says ${says feature}"
                ) features
              )
          ) (edgeRoutersOf name)
        )
      ) edgeRoutes
    );

    # the owner's rule: an onion visitor is always asked, whatever its route's features say
    "onion captcha" =
      lib.concatLists (
        lib.mapAttrsToList (
          name: router:
          let
            flags = gateFlags edge router;
          in
          if flags == null then
            [ "vm-200 onion router ${name} has no gate" ]
          else
            lib.optional (
              (flags.captcha or "0") != "1"
            ) "vm-200 onion router ${name}: the gate's captcha is ${flags.captcha or "absent"}"
        ) onionRouters
      )
      ++ map (address: "vm-200's gate does not know the onion address ${address}") (
        lib.subtractLists (lib.attrValues ((gateOf edge).captcha.onions or { })) onionAddresses
      );

    # a search crawler reads an indexable route's own robots.txt and passes the gate's, anubis' and crowdsec's checks of
    # its ranges and reverse dns, its user agent from anywhere else gets the deception (gate's crawlers above);
    # everywhere else it reads the lab's disallow-all
    "indexable" =
      map (h: "vm-200 answers ${net.fqdn h}'s robots.txt with the lab's disallow-all, its route is indexable") (
        lib.filter (h: !(robotsSpared h)) indexableHosts
      )
      ++ map (h: "vm-200 leaves ${net.fqdn h}'s robots.txt to its backend, no route of it is indexable") (
        lib.filter robotsSpared robotsCovered
      )
      ++ lib.optionals (indexableHosts != [ ]) (
        lib.optional (
          edge.services.anubis.instances.ingress.settings.POLICY_FNAME == null
        ) "vm-200's anubis runs its bundled policy alone, which passes a crawler's user agent from any address"
        ++ lib.optional (
          !(lib.elem "crowdsecurity/whitelist-good-actors" crowdsecCollections)
        ) "vm-200's crowdsec may ban search crawlers: crowdsecurity/whitelist-good-actors is not installed"
      );

    "deception" = lib.concatLists (
      lib.mapAttrsToList (
        host: config:
        let
          http = httpOf config;
          settings = gateOf config;
          deception = {
            gate-deception = settings.deception.statusDeceive;
            gate-deception-crawler = settings.deception.statusForgedCrawler;
          };
          wrapped = [
            "gate-deception-crawler"
            "gate-deception"
          ];
          inherit (config.homelab.traefik.crowdsecBouncer) profiles;
          deceives = lib.filter (p: lib.any (d: d.type == "deceive") p.decisions) profiles;
        in
        lib.concatLists (
          lib.mapAttrsToList (
            name: router:
            let
              chain = router.middlewares or [ ];
              gate = gateOfRouter config router;
              at = lib.lists.findFirstIndex (m: m == gate) null chain;
            in
            lib.optional (
              gate != null && (at < lib.length wrapped || lib.sublist (at - lib.length wrapped) (lib.length wrapped) chain != wrapped)
            ) "${host} router ${name}: its gate is not wrapped by the deception's errors middlewares"
          ) http.routers
        )
        ++ lib.optional (settings.crawlers == [ ]) "${host}'s gate knows no search crawler to tell a forged one by"
        # a published list goes stale: a real crawler from a newer range would be deceived and banned for the day
        ++ map (c: "${host}'s gate calls ${c.name} forged on its published list alone, without reverse dns") (
          lib.filter (c: c.reverseDomains == [ ]) settings.crawlers
        )
        ++ lib.concatMap (
          scenario:
          let
            first = firstRungOf profiles scenario;
          in
          if first == null then
            [ "${host}'s crowdsec decides nothing on ${scenario}'s first alert" ]
          else
            lib.optional (lib.any (d: d.type == "deceive" || (d.type == "ban" && durationSeconds d.duration >= daySeconds))
              first.decisions
            ) "${host}'s profile ${first.name} bans ${scenario}, which a browser trips, for a day on its first alert"
        ) browserTrippable
        ++ lib.concatMap (
          scenario:
          let
            first = firstRungOf profiles scenario;
          in
          lib.optional (
            first == null || !lib.any (d: d.type == "deceive") first.decisions
          ) "${host}'s crowdsec does not deceive ${scenario} on its first alert"
          ++ lib.optional (
            first != null && lib.any (d: d.type == "ban" && durationSeconds d.duration >= daySeconds) first.decisions
          ) "${host}'s profile ${first.name} bans ${scenario}, which a shared address trips, for a day on its first alert"
        ) sharedAddressDeceived
        ++ lib.concatLists (
          lib.mapAttrsToList (
            middleware: status:
            let
              errors = http.middlewares.${middleware}.errors or { };
              servers = http.services.${errors.service or ""}.loadBalancer.servers or [ ];
            in
            lib.optional
              (
                errors.status or [ ] != [ (toString status) ]
                || errors.statusRewrites or { } != { ${toString status} = 200; }
                || servers != [ { url = "http://${settings.deception.listen}"; } ]
              )
              "${host}'s ${middleware} middleware catches more than the gate's status ${toString status} or sends it elsewhere than the deception"
          ) deception
        )
        ++ lib.optional (deceives == [ ]) "${host}'s crowdsec deceives no scanner"
        ++ lib.concatMap (
          p:
          let
            seconds = type: map (d: durationSeconds d.duration) (lib.filter (d: d.type == type) p.decisions);
          in
          lib.optional (
            !(lib.any (ban: lib.all (deceive: ban > deceive) (seconds "deceive")) (seconds "ban"))
          ) "${host}'s profile ${p.name} deceives without a ban outlasting it"
          ++ map (scenario: "${host}'s profile ${p.name} deceives ${scenario}, brute force, which is banned at once") (
            lib.filter bruteForce (profileScenarios p)
          )
        ) deceives
      ) (lib.filterAttrs (_: config: config.homelab.traefik.crowdsecBouncer.enable) ingresses)
    );

    "captcha" =
      lib.optional ((gateOf edge).captcha == null) "vm-200, the internet's ingress, asks no captcha"
      ++ lib.concatLists (
        lib.mapAttrsToList (
          host: config:
          lib.optional (
            ((gateOf config).captcha.answerLog or null) != null
          ) "${host} logs every captcha's answer (a vm test's hook)"
        ) configs
      );
  }
)
