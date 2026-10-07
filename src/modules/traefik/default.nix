# traefik with the lab's defences, for both ingresses (100-internal, 200-external)
#
# The routes an ingress serves (`routes`, modules/catalog.nix records of modules/service.nix) become its routers,
# services and middlewares here, each feature on unless the route's `off` names it: client-ip (the real client into
# X-Real-Ip, lib/traefik-clientip), the strip of client-sent identity and target headers, cloudflare-only, the
# crowdsec bouncer with its AppSec waf and the core rule set, the per-client and per-route rate and in-flight
# limits, the body limit, retries, the security headers, then sso, anubis, basic auth and the route's own headers.
# A hand-written router gets the same chain and may name opt-outs in an `off` attribute of its own. Every quantity
# that names a client reads X-Real-Ip, which client-ip sets from the socket peer and the X-Forwarded-For hops of
# trustedProxies and Cloudflare only; the backend's X-Forwarded-For is that client alone. The probers check a route
# at its health path through the ingress, past sso and anubis but nowhere else (probe routers below).
{ config, lib, pkgs, retry, inventory, site, lab, catalog, ... }:
let
  cfg = config.homelab.traefik;
  net = import ../net.nix { inherit lib inventory site; };
  service = import ../service.nix { inherit lib; };
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  htpasswd = import ./lib/htpasswd.nix { inherit pkgs lib; };
  inherit (net) cloudflareRanges privateRanges;

  # the prober (vm-105's blackbox) and the dashboard's status dots (vm-103)
  probeSources = map net.hostSource [ telemetry.collectorVmid (toString lab.routes.homepage.vmid) ];
  probeMethods = [ "GET" "HEAD" ];
  # a route kept off the internet answers the networks the router lets into the internal zone, never a dmz
  internalOnlySources = [ net.wan.subnet net.wireguard.subnet net.zones.internal.subnet ];

  # whose X-Forwarded-For hops count: the entrypoint keeps them, client-ip and the bouncer walk past them
  trustedHops = cfg.trustedProxies ++ lib.optionals cfg.trustCloudflare cloudflareRanges;
  loopback = "127.0.0.1";
  logDir = "/var/log/traefik";
  crowdsecDir = "/var/lib/crowdsec";

  # loopback ports of the bot defence: iocaine's labyrinth and the nginx serving robots.txt and llms.txt
  iocainePort = 42069;
  wellKnownPort = 8083;
  # crowdsec's local api, published from its container on loopback
  crowdsecLapiPort = 8180;
  crowdsecLapiContainerPort = 8080;
  # the one anubis instance, its metrics, and the loopback entrypoint it hands solved requests back to
  anubisPort = 27000;
  anubisMetricsPort = 28000;
  anubisBalancerPort = 28080;

  # exact paths nothing legitimate requests, never prefixes: /.git/ would catch a forgejo repo named for it
  honeypotPaths = [
    # disclosed only in robots.txt
    "/internal/export"
    # never disclosed
    "/wp-login.php"
    "/wp-admin/setup-config.php"
    "/.env"
    "/.git/config"
    "/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php"
  ];

  # proof-of-work leading zero bits, higher costs every client more cpu
  anubisDifficulty = 4;

  # authelia's answer to forwardauth; a client sending its own must never reach an app that trusts them
  identityHeaders = [ "Remote-User" "Remote-Groups" "Remote-Email" "Remote-Name" ];
  # what forwardauth and apps read as the request's target, dropped whoever sent them: a client naming auth.<domain>
  # would pass its bypass rule. X-Forwarded-For/-Proto and X-Real-Ip stay, the entrypoint keeps them from trustedHops only
  forwardedTargetHeaders = [
    "X-Forwarded-Host" "X-Forwarded-Uri" "X-Forwarded-Method" "X-Forwarded-Port" "X-Forwarded-Prefix" "X-Forwarded-Server"
  ];

  stripClientHeadersMiddleware = {
    strip-client-headers.headers.customRequestHeaders = lib.genAttrs (identityHeaders ++ forwardedTargetHeaders) (_: "");
  };

  autheliaMiddleware = lib.optionalAttrs (cfg.authelia.address != null) {
    authelia.forwardAuth = {
      inherit (cfg.authelia) address;
      # safe since the strip above: with no target header left, traefik sends the host and uri it routed, and
      # trusting the rest passes authelia the real client ip from the X-Forwarded-For chain, for its logs and bans
      trustForwardHeader = true;
      authResponseHeaders = identityHeaders;
    };
  };

  # header hardening on every websecure route
  baseSecureHeaders = {
    stsSeconds = 31536000;
    stsIncludeSubdomains = true;
    stsPreload = true;
    contentTypeNosniff = true;
    browserXssFilter = true;
    referrerPolicy = "strict-origin-when-cross-origin";
  };

  secureHeadersMiddleware = {
    secure-headers.headers = baseSecureHeaders // { frameDeny = true; };
    # for apps that frame themselves
    secure-headers-sameorigin.headers =
      baseSecureHeaders // { customFrameOptionsValue = "SAMEORIGIN"; };
    # the url is the content: a search engine's query must not ride along to the next page
    secure-headers-noreferrer.headers = baseSecureHeaders // { frameDeny = true; referrerPolicy = "no-referrer"; };
  };

  # per-client dos limits: a page load fans out to tens of requests, an api client to a few a second
  rateLimitAverage = 50;   # req/s sustained
  rateLimitBurst = 100;    # spikes above average
  inFlightAmount = 100;    # concurrent requests
  # a login is a person typing: five tries a minute, a burst of ten for a password manager retrying
  loginRateLimitAverage = 5;
  loginRateLimitBurst = 10;
  loginRateLimitPeriod = "1m";

  # client-ip wrote the real client here, for every source alike
  clientSource.requestHeaderName = "X-Real-Ip";
  # what one route admits from all its clients together (modules/limits): traefik builds a middleware per
  # router, so one definition is a budget per route, and a crowd flooding one app never reaches the others' share
  routeLimits = import ../limits { inherit lib; };
  routeBudget = routeLimits.route;
  routeSource.requestHost = true;

  limitMiddlewares = {
    rate-limit.rateLimit = {
      average = rateLimitAverage;
      burst = rateLimitBurst;
      period = "1s";
      sourceCriterion = clientSource;
    };
    inflight-limit.inFlightReq = {
      amount = inFlightAmount;
      sourceCriterion = clientSource;
    };
    route-rate-limit.rateLimit = {
      inherit (routeBudget) average burst;
      period = "1s";
      sourceCriterion = routeSource;
    };
    route-inflight-limit.inFlightReq = {
      amount = routeBudget.inFlight;
      sourceCriterion = routeSource;
    };
    # password endpoints a route names in `loginPaths`: brute force stops here, whatever the app does
    rate-limit-login.rateLimit = {
      average = loginRateLimitAverage;
      burst = loginRateLimitBurst;
      period = loginRateLimitPeriod;
      sourceCriterion = clientSource;
    };
    client-ip.plugin.client-ip.trustedIPs = trustedHops;
    # anubis hands a request back with the client client-ip named, then its own hop
    client-ip-anubis.plugin.client-ip.trustedIPs = [ "${loopback}/32" ];
    # retry requests that never reached the backend
    retry-upstream.retry = {
      attempts = 4;
      initialInterval = "500ms";
    };
    # answers 403 to everyone: paths a route must never serve, like an app's own metrics
    deny-all.ipAllowList.sourceRange = [ "255.255.255.255/32" ];
  } // lib.optionalAttrs cfg.cloudflareOnly.enable {
    # proxying only protects if the origin refuses others; loopback is the edge's own anubis handing back
    cloudflare-only.ipAllowList.sourceRange = cloudflareRanges ++ privateRanges ++ [ "${loopback}/32" ];
  } // lib.listToAttrs (map (bytes: lib.nameValuePair "body-limit-${toString bytes}" {
    buffering = {
      maxRequestBodyBytes = bytes;
      # spill to disk past 1 mib
      memRequestBodyBytes = 1048576;
      maxResponseBodyBytes = 0;
    };
  }) (lib.unique (map (r: r.bodyLimitBytes) (lib.filter (r: on r "bodyLimit") (map recordOf (lib.attrValues allRouters))))));

  # user agents served the labyrinth
  labyrinthUserAgents = [
    # model trainers and retrieval agents
    "GPTBot" "ChatGPT-User" "OAI-SearchBot" "ClaudeBot" "Claude-Web"
    "Claude-SearchBot" "Claude-User" "anthropic-ai" "CCBot" "Bytespider"
    "Amazonbot" "Applebot-Extended" "Google-Extended" "PerplexityBot"
    "Perplexity-User" "Diffbot" "FacebookBot" "meta-externalagent"
    "meta-externalfetcher" "ImagesiftBot" "Omgilibot" "Timpibot" "YouBot"
    "cohere-ai" "cohere-training-data-crawler" "Kangaroo Bot" "PanguBot"
    "Webzio-Extended" "AI2Bot" "Ai2Bot-Dolma" "MistralAI-User" "DeepSeek"
    "FirecrawlAgent" "Firecrawl" "img2dataset" "VelenPublicWebCrawler"
    "Brightbot" "iaskspider" "ProRataInc" "TikTokSpider" "Sidetrade"
    # generic scrapers and seo crawlers
    "Scrapy" "SemrushBot" "AhrefsBot" "DotBot" "MJ12bot" "DataForSeoBot"
    "PetalBot" "Barkrowler" "SeekportBot" "Awario" "peer39_crawler"
  ];

  appsecPort = 7422;

  # crowdsec's config files, json documents (json is yaml), several to a file split by ---
  yamlDocs = name: docs: pkgs.writeText name (lib.concatMapStringsSep "---\n" (doc: builtins.toJSON doc + "\n") docs);

  # the hub's blocking crs, minus its anomaly verdict (949110) on anubis' own challenge endpoints, which
  # trip it with their proof-of-work payload; webapp-template's modsecurity carried the same exclusion
  crsConfig = yamlDocs "homelab-crs.yaml" [{
    name = "homelab/crs-inband";
    default_remediation = "ban";
    inband_rules = [ "crowdsecurity/crs" ];
    pre_eval = [{
      filter = "IsInBand == true && req.URL.Path startsWith \"/.within.website/\"";
      apply = [ "RemoveInBandRuleByID(949110)" ];
    }];
  }];

  # the waf: crowdsec's virtual patching and generic rules plus the owasp core rule set
  appsecAcquis = yamlDocs "appsec-acquis.yaml" [{
    source = "appsec";
    # inside the container, which publishes it on loopback only
    listen_addr = "0.0.0.0:${toString appsecPort}";
    appsec_configs = [ "crowdsecurity/appsec-default" "homelab/crs-inband" ];
    labels.type = "appsec";
  }];

  traefikAcquis = yamlDocs "traefik-acquis.yaml" [{
    source = "file";
    filenames = [ cfg.accessLog ];
    labels.type = "traefik";
  }];

  # crowdsec never bans these
  whitelistParser = yamlDocs "homelab-whitelist.yaml" [{
    name = "homelab/whitelist";
    description = "homelab trusted networks";
    whitelist = { reason = "homelab trusted networks"; cidr = cfg.crowdsecBouncer.whitelistCidrs; };
  }];

  # the plugins, pinned and local: traefik would otherwise fetch a tag from github at every start, so a lab booting
  # without wan served no route that names one, and ran whatever the tag pointed at that day
  bouncerPlugin = {
    moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin";
    src = pkgs.fetchFromGitHub {
      owner = "maxlerebourg";
      repo = "crowdsec-bouncer-traefik-plugin";
      rev = "v1.4.5";
      hash = "sha256-Bb70z1xViwtWKbeERaBQdaugyCFYXLkQI1kpEJLOYkE=";
    };
  };
  # the lab's own, in this repo (tests/traefik-clientip.nix runs its go tests)
  clientIpPlugin = {
    moduleName = "github.com/lsck0/homelab/clientip";
    src = lib.fileset.toSource {
      root = ./lib/traefik-clientip;
      fileset = lib.fileset.difference ./lib/traefik-clientip ./lib/traefik-clientip/clientip_test.go;
    };
  };
  plugins = [ clientIpPlugin ] ++ lib.optional cfg.crowdsecBouncer.enable bouncerPlugin;
  # traefik loads local plugins from plugins-local/src/<moduleName> below its working directory, its dataDir
  pluginsLocal = pkgs.linkFarm "traefik-plugins-local" (map (p: { name = "src/${p.moduleName}"; path = p.src; }) plugins);

  mkBouncer = appsec: {
    plugin.crowdsec-bouncer = {
      enabled = true;
      crowdsecMode = "live";
      crowdsecLapiScheme = "http";
      crowdsecLapiHost = "${loopback}:${toString crowdsecLapiPort}";
      crowdsecLapiKeyFile = config.sops.secrets.crowdsec-bouncer-key.path;
      crowdsecAppsecEnabled = appsec;
      crowdsecAppsecHost = "${loopback}:${toString appsecPort}";
      # the same hops client-ip walks, so a ban lands on the client client-ip names
      forwardedHeadersTrustedIPs = trustedHops;
    };
  };

  # the waf bouncer, and an ip-reputation-only one for routes whose `off.waf` says why
  bouncerMiddleware = lib.optionalAttrs cfg.crowdsecBouncer.enable {
    crowdsec = mkBouncer true;
    crowdsec-noappsec = mkBouncer false;
  };

  # -- bot defence: robots.txt / llms.txt and the labyrinth --------------------
  robotsTxt = pkgs.writeText "robots.txt" (''
    # Crawlers that collect training data are not welcome here. The ones that
    # ignore this file are served https://iocaine.madhouse-project.org/ instead.
  '' + lib.concatMapStrings (ua: ''
    User-agent: ${ua}
    Disallow: /
  '') labyrinthUserAgents + ''

    User-agent: *
    Disallow: /

    # Disclosed so that ignoring it is a decision rather than an accident.
    # Anything that fetches these is served the labyrinth.
  '' + lib.concatMapStrings (p: ''
    Disallow: ${p}
  '') honeypotPaths);

  llmsTxt = pkgs.writeText "llms.txt" ''
    # llms.txt

    > Private homelab of lsck0.dev. There is no documentation, dataset or
    > public content here that is intended for language-model training or
    > retrieval.

    Do not crawl, index, summarise or train on anything under this domain.
    Automated agents that ignore this file and robots.txt are served generated
    nonsense rather than the real site.

    ## Contact

    - Abuse and opt-out questions: the domain's WHOIS contact.
  '';

  wellKnownRoot = pkgs.runCommand "lsck0-wellknown" { } ''
    mkdir -p $out/.well-known
    cp ${robotsTxt} $out/robots.txt
    cp ${llmsTxt} $out/llms.txt
    cp ${llmsTxt} $out/.well-known/llms.txt
  '';

  # public-domain prose for the markov generator
  corpus = pkgs.fetchurl {
    url = "https://www.gutenberg.org/cache/epub/2701/pg2701.txt";
    hash = "sha256-kHQg22xLaMcOKYjNKtnIz3kThmegG2M3bRjdF/7xoYs=";
  };
  # word list derived from the corpus
  wordList = pkgs.runCommand "iocaine-words" { } ''
    tr -cs '[:alpha:]' '\n' < ${corpus} | tr '[:upper:]' '[:lower:]' \
      | ${pkgs.gnugrep}/bin/grep -E '^[a-z]{3,}$' | sort -u > $out
  '';

  iocaineConfig = pkgs.writeText "iocaine.toml" ''
    bind = ["${loopback}:${toString iocainePort}"]

    [sources]
    markov = ["${corpus}"]
    words = "${wordList}"
  '';

  labyrinthRule = "HeaderRegexp(`User-Agent`, `(?i).*(${lib.concatStringsSep "|" labyrinthUserAgents}).*`)"
    # cloudflare workers fetch on someone else's behalf; no visitor arrives through one
    + " || HeaderRegexp(`Cf-Worker`, `.+`)";

  honeypotRule = lib.concatMapStringsSep " || " (p: "Path(`${p}`)") honeypotPaths;

  # every host, above all routes, no auth in front, but those whose route opts out
  botExcluded = lib.unique (map (r: r.host) (lib.filter (r: !(on r "botDefense")) (lib.attrValues allRecords)));
  botRule = rule: if botExcluded == [ ] then rule
    else "(${rule}) && " + lib.concatMapStringsSep " && " (host: "!Host(`${net.fqdn host}`)") botExcluded;
  # unproxied hosts serve robots.txt and the labyrinth too, to clients that reach them directly
  botOff = { cloudflare = "it answers every host, unproxied ones included"; };
  botDefenseRouters = lib.optionalAttrs cfg.botDefense.enable {
    wellknown-tls = {
      rule = botRule "Path(`/robots.txt`) || Path(`/llms.txt`) || Path(`/.well-known/llms.txt`)";
      service = "wellknown";
      entryPoints = [ "websecure" ];
      priority = 10000;
      off = botOff;
    };
    labyrinth-tls = {
      rule = botRule labyrinthRule;
      service = "labyrinth";
      entryPoints = [ "websecure" ];
      priority = 9000;
      off = botOff;
    };
    # above real routes, below robots.txt
    honeypot-tls = {
      rule = botRule honeypotRule;
      service = "labyrinth";
      entryPoints = [ "websecure" ];
      priority = 9500;
    };
  };

  botDefenseServices = lib.optionalAttrs cfg.botDefense.enable {
    wellknown.loadBalancer.servers = [{ url = "http://${loopback}:${toString wellKnownPort}"; }];
    labyrinth.loadBalancer.servers = [{ url = "http://${loopback}:${toString iocainePort}"; }];
  };

  # -- routes: every router, service and middleware a route needs -------------------------------------------

  # a feature is on unless the record's `off` names it; a hand-written router's record is its `off` on service.nix's defaults
  on = r: feature: (r.off.${feature} or null) == null;
  recordOf = router: router.route or {
    off = router.off or { };
    frames = "deny";
    referrer = true;
    bodyLimitBytes = service.bodyLimitDefaultBytes;
    sources = null;
  };
  allRecords = cfg.routes // cfg.relays;
  # sso stops bots before the app already: anubis runs only where sso does not (modules/service.nix)
  anubisOn = r: on r "anubis" && !(on r "sso");
  anubisRoutes = lib.filterAttrs (_: anubisOn) cfg.routes;

  fqdnRule = r: "Host(`${net.fqdn r.host}`)" + lib.optionalString (r.path != "/") " && PathPrefix(`${r.path}`)";
  anyOf = matcher: values: "(${lib.concatMapStringsSep " || " (v: "${matcher}(`${v}`)") values})";
  # admitted sources are part of the rule: another client falls through to the host's other routes, or a 404
  routeRule = r: "${fqdnRule r} && ${anyOf "Method" r.methods}" + lib.optionalString (r.sources != null) " && ${anyOf "ClientIP" r.sources}";

  routeMiddlewares = name: r: lib.optional (on r "sso") "authelia"
    ++ lib.optional (r.loginRedirect != null) "${name}-login"
    ++ lib.optional (r.basicAuth != null) "${name}-auth"
    ++ lib.optional (r.headers != { }) "${name}-headers"
    # the template's nginx compressed for its browsers; nixos services answer as they choose
    ++ lib.optional (r.app != null) "compress";

  routeRouters = lib.concatMapAttrs (name: r: {
    "${name}-tls" = {
      rule = routeRule r;
      service = if anubisOn r then "anubis" else name;
      entryPoints = [ "websecure" ];
      middlewares = routeMiddlewares name r;
      route = r;
    };
  } // lib.optionalAttrs (r.loginPaths != [ ]) {
    # password endpoints: the route's rule and chain plus the login limit; the longer rule outranks the route's own
    "${name}-login-tls" = {
      rule = "${routeRule r} && ${anyOf "PathPrefix" r.loginPaths}";
      service = name;
      entryPoints = [ "websecure" ];
      middlewares = routeMiddlewares name r ++ [ "rate-limit-login" ];
      route = r;
    };
  } // lib.optionalAttrs (anubisOn r) {
    # what anubis lets through comes back on loopback and goes to the route's backend
    "${name}-balancer" = { rule = fqdnRule r; service = name; entryPoints = [ "anubis-balancer" ]; middlewares = [ "client-ip-anubis" ]; };
  }) cfg.routes;

  # the probers' door: GET and HEAD of the health path from their addresses, to the backend past sso and anubis
  probeOn = r: r.health != null && on r "probe";
  probeRoutes = lib.filterAttrs (_: probeOn) cfg.routes;
  probesOutsideRoute = lib.attrNames (lib.filterAttrs (_: r: !(lib.hasPrefix r.path r.health)) probeRoutes);
  probeRouters = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-probe" {
    rule = "${fqdnRule r} && Path(`${r.health}`) && ${anyOf "Method" probeMethods} && ${anyOf "ClientIP" probeSources}";
    service = name;
    entryPoints = [ "websecure" ];
    route = r // { off = r.off // { accessLog = "a probe every few seconds would bury the clients' requests"; }; };
  }) probeRoutes;

  # an instance route to its guest (or its on-demand proxy), an app route to every node of its cluster, health-checked
  serversOf = name: r:
    if config.homelab.onDemand.address ? ${name} then [ "http://${config.homelab.onDemand.address.${name}}" ]
    else if r.vmid != null then [ "http://${inventory.${toString r.vmid}.ip}:${toString r.port}" ]
    else map (ip: "http://${ip}:${toString r.port}") r.nodes;
  routeServices = lib.mapAttrs (name: r: let servers = serversOf name r; in {
    loadBalancer = { servers = map (url: { inherit url; }) servers; }
      // lib.optionalAttrs (r.health != null && lib.length servers > 1) {
        healthCheck = { path = r.health; interval = "10s"; timeout = "3s"; };
      };
  }) cfg.routes // lib.optionalAttrs (anubisRoutes != { }) {
    anubis.loadBalancer.servers = [{ url = "http://${loopback}:${toString anubisPort}"; }];
  };

  routeMiddlewareDefs = lib.concatMapAttrs (name: r:
    lib.optionalAttrs (r.loginRedirect != null) {
      # the app's login page goes to its sso flow, whatever query it carries (?redirect_to= still served the form)
      "${name}-login".redirectRegex = {
        regex = "^https://${lib.escapeRegex (net.fqdn r.host)}${lib.escapeRegex r.loginRedirect.path}(\\?.*)?$";
        replacement = "https://${net.fqdn r.host}${r.loginRedirect.to}";
      };
    } // lib.optionalAttrs (r.basicAuth != null) {
      # the header goes on: a backend checks the same users again (118's registry)
      "${name}-auth".basicAuth = { usersFile = "${basicAuthDir}/${name}"; realm = name; removeHeader = false; };
    } // lib.optionalAttrs (r.headers != { }) {
      "${name}-headers".headers = r.headers;
    }) cfg.routes // {
    compress.compress = { };
  } // lib.optionalAttrs (cfg.relays != { }) {
    # a route without `internet`: the edge relays it to the house, wireguard and the internal zone only
    internal-only.ipAllowList.sourceRange = internalOnlySources;
  };

  # -- frontend telemetry: the browser's otlp beacons on the app's own origin, to the collector ----------------

  # same origin: no cors, and a route behind sso keeps it, the session cookie rides along; anubis would stop the
  # beacons, the body limit bounds what an unauthenticated public input may send
  frontendBodyBytes = routeLimits.frontend.bodyBytes;
  frontendOn = r: (if r.app == null then r.off else catalog.apps.${r.app}.off).frontend == null;
  # one intake per host, named after its first route
  frontendRoutes = lib.listToAttrs (map (e: lib.nameValuePair e.value.host e) (lib.reverseList
    (lib.filter (e: frontendOn e.value) (lib.attrsToList cfg.routes))));
  frontendRouters = lib.mapAttrs' (host: e: lib.nameValuePair "${e.name}-otlp" {
    rule = "Host(`${net.fqdn host}`) && PathPrefix(`${telemetry.frontendPath}`) && Method(`POST`)";
    service = "frontend-intake";
    entryPoints = [ "websecure" ];
    middlewares = lib.optional (on e.value "sso") "authelia" ++ [ "${e.name}-otlp-tenant" ];
    route = e.value // {
      off = e.value.off // { anubis = "browser beacons run no proof of work"; };
      bodyLimitBytes = frontendBodyBytes;
    };
  }) frontendRoutes;
  frontendMiddlewares = lib.mapAttrs' (_: e: lib.nameValuePair "${e.name}-otlp-tenant" {
    # the collector keys its limits on the tenant; a client's own header is replaced
    headers.customRequestHeaders.${telemetry.tenantHeader} = telemetry.tenantOf (if e.value.app == null then e.name else e.value.app);
  }) frontendRoutes;
  frontendServices = lib.optionalAttrs (frontendRoutes != { }) {
    frontend-intake.loadBalancer.servers = [{ url = telemetry.urls.frontendIntake; }];
  };

  # -- relays: the edge forwards every internal route to the internal ingress, over tls verified for its host ---

  relayRouters = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-relay" ({
    rule = "Host(`${net.fqdn r.host}`)";
    service = "${name}-relay";
    entryPoints = [ "websecure" ];
    middlewares = lib.optional (!(on r "internet")) "internal-only";
    route = r;
  })) cfg.relays;
  relayServices = lib.mapAttrs' (name: _: lib.nameValuePair "${name}-relay" {
    loadBalancer = { servers = [{ url = cfg.relayTarget; }]; serversTransport = "${name}-relay"; passHostHeader = true; };
  }) cfg.relays;
  relayTransports = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-relay" { serverName = net.fqdn r.host; }) cfg.relays;

  # -- basic auth: htpasswd files rendered from sops, the passwords never on an argv ----------------------------

  basicAuthDir = "/run/traefik-auth";
  basicAuthRoutes = lib.filterAttrs (_: r: r.basicAuth != null) cfg.routes;
  basicAuthSecrets = lib.unique (lib.concatMap (r: lib.attrValues r.basicAuth) (lib.attrValues basicAuthRoutes));

  # every websecure router's chain, ahead of its own middlewares; the strip runs before a router's own authelia sets
  # the identity, cloudflare-only refuses a direct caller before the waf spends anything on it
  chainOf = name: r:
    [ "client-ip" "strip-client-headers" ]
    # a route kept off the internet admits private sources only, cloudflare's included in none
    ++ lib.optional (cfg.cloudflareOnly.enable && on r "cloudflare" && on r "internet") "cloudflare-only"
    # scanners must reach the labyrinth, past the waf
    ++ lib.optional (cfg.crowdsecBouncer.enable && on r "crowdsec")
      (if on r "waf" && name != "honeypot-tls" then "crowdsec" else "crowdsec-noappsec")
    ++ lib.optionals (on r "rateLimit") [ "rate-limit" "route-rate-limit" ]
    ++ lib.optionals (on r "inflightLimit") [ "inflight-limit" "route-inflight-limit" ]
    # buffered once, outside the retry: a retry inside the buffer re-read a consumed body and sent it empty
    ++ lib.optional (on r "bodyLimit") "body-limit-${toString r.bodyLimitBytes}"
    ++ [ "retry-upstream" ]
    ++ lib.optional (on r "secureHeaders") (
      if r.frames == "sameorigin" then "secure-headers-sameorigin"
      else if !r.referrer then "secure-headers-noreferrer"
      else "secure-headers");

  # bound slow-dribbling clients
  respondingTimeouts = { readTimeout = "120s"; writeTimeout = "0s"; idleTimeout = "180s"; };

  # one wildcard certificate per ingress: one acme order, and no route's name in the certificate transparency logs
  wildcardTls = { certResolver = "cloudflare"; domains = [{ main = net.domain; sans = [ "*.${net.domain}" ]; }]; };

  # a refused client matches no router here, bot defence included (a 404); a route admitting named sources decides itself
  refuse = r: rule:
    if cfg.refusedClients == [ ] || r.sources != null then rule
    else "(${rule}) && " + lib.concatMapStringsSep " && " (range: "!ClientIP(`${range}`)") cfg.refusedClients;

  routersWithTls = lib.mapAttrs (name: router: let r = recordOf router; in
    removeAttrs router [ "route" "off" ] // lib.optionalAttrs (lib.elem "websecure" (router.entryPoints or [ ])) {
      rule = refuse r router.rule;
      tls = wildcardTls // (router.tls or { });
      middlewares = chainOf name r ++ (router.middlewares or [ ]);
    } // lib.optionalAttrs (!(on r "accessLog")) { observability.accessLogs = false; }
  ) allRouters;
  allRouters = cfg.routers // routeRouters // probeRouters // frontendRouters // relayRouters // botDefenseRouters;
  allMiddlewares = cfg.middlewares // routeMiddlewareDefs // frontendMiddlewares // secureHeadersMiddleware // limitMiddlewares
    // bouncerMiddleware // stripClientHeadersMiddleware // autheliaMiddleware;
  missingMiddlewares = lib.subtractLists (lib.attrNames allMiddlewares)
    (lib.unique (lib.concatMap (r: r.middlewares or [ ]) (lib.attrValues routersWithTls)));

  # every loopback port this host's traefik and its helpers bind, which must be pairwise distinct
  loopbackPorts = [
    { name = "iocaine"; port = iocainePort; }
    { name = "wellknown nginx"; port = wellKnownPort; }
    { name = "crowdsec lapi"; port = crowdsecLapiPort; }
    { name = "crowdsec appsec"; port = appsecPort; }
  ] ++ lib.optionals (anubisRoutes != { }) [
    { name = "anubis"; port = anubisPort; }
    { name = "anubis metrics"; port = anubisMetricsPort; }
    { name = "anubis balancer"; port = anubisBalancerPort; }
  ] ++ lib.mapAttrsToList (name: port: { name = "port ${name}"; inherit port; }) cfg.loopbackPorts;
  loopbackClashes = lib.filter (group: lib.length group > 1)
    (lib.attrValues (lib.groupBy (p: toString p.port) loopbackPorts));
in {
  # every instance route reaches its guest through the on-demand proxy
  imports = [ ../on-demand ];

  options.homelab.traefik = let
    # traefik's own dynamic configuration, merged with what the routes derive
    passthrough = what: lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; description = "Traefik ${what}."; };
    records = what: lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Route name -> its record (modules/catalog.nix): ${what}.";
    };
  in {
    enable = lib.mkEnableOption "Traefik reverse proxy with ACME and CrowdSec";

    entryPoints = passthrough "entrypoints beyond web, websecure and metrics";
    routers = passthrough "http routers of the ingress's own, protected like a route (an `off` attribute opts out)";
    services = passthrough "http services";
    middlewares = passthrough "http middlewares";
    serversTransports = passthrough "servers transports";

    routes = records "this ingress's routers, services and middlewares";
    relays = records "routes of another ingress, forwarded to relayTarget by host";
    relayTarget = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "The ingress the relays go to."; };

    # private sources stay allowed, so this cannot lock the house out
    cloudflareOnly.enable = lib.mkEnableOption "refusing direct callers on every router whose route keeps the `cloudflare` feature";

    botDefense.enable = lib.mkEnableOption "robots.txt and llms.txt on every host, the iocaine labyrinth for crawlers ignoring them";

    crowdsecBouncer = {
      enable = lib.mkEnableOption "crowdsec on the access log and its bouncer, with the waf, on every route";
      whitelistCidrs = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Sources crowdsec never bans."; };
    };

    # set, it defines the `authelia` middleware; a client's X-Forwarded-* never reaches it, only its Remote-* the app
    authelia.address = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Authelia's forward-auth endpoint."; };
    # without them every relayed request is the relay's, and the per-client limits share one bucket
    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Proxies relaying here whose X-Forwarded-For hops client-ip believes.";
    };
    # cloudflare's own X-Real-Ip is never believed, a client can set it
    trustCloudflare = lib.mkEnableOption "believing Cloudflare's X-Forwarded-For hops";
    refusedClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Sources no websecure router answers, but routes that admit them by `sources`.";
    };
    loopbackPorts = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = { };
      description = "The host's other loopback listeners, checked for clashes with traefik's own.";
    };
    accessLog = lib.mkOption { type = lib.types.str; readOnly = true; default = "${logDir}/access.log"; description = "Traefik's json access log."; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = loopbackClashes == [ ];
      message = "${config.networking.hostName}: loopback ports bound twice: "
        + lib.concatMapStringsSep "; " (group: "${toString (lib.head group).port} by ${lib.concatMapStringsSep ", " (p: p.name) group}") loopbackClashes;
    } {
      # a health path outside the route's prefix matches none of its routers: every probe would answer 404
      assertion = probesOutsideRoute == [ ];
      message = "${config.networking.hostName}: routes whose health path lies outside their path: ${toString probesOutsideRoute}";
    } {
      # traefik drops a router naming a missing middleware and answers its host with a 404
      assertion = missingMiddlewares == [ ];
      message = "${config.networking.hostName}: routers name middlewares nothing defines: ${toString missingMiddlewares}";
    }];

    sops.templates."traefik.env".content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
    '';

    virtualisation.oci-containers.containers.crowdsec = lib.mkIf cfg.crowdsecBouncer.enable {
      # the tag for reading, the digest for what runs
      image = "crowdsecurity/crowdsec:v1.7.7@sha256:6ca53ad26196ca59ddd4fa692a586b73d8fcde085046163b9ca2f04887dca563";
      volumes = [
        "${crowdsecDir}/config:/etc/crowdsec"
        "${crowdsecDir}/data:/var/lib/crowdsec/data"
        "${logDir}:${logDir}:ro"
      ];
      ports = [
        "${loopback}:${toString crowdsecLapiPort}:${toString crowdsecLapiContainerPort}"
        "${loopback}:${toString appsecPort}:${toString appsecPort}"
      ];
      environment.COLLECTIONS = lib.concatStringsSep " " [
        "crowdsecurity/traefik" "crowdsecurity/http-cve" "crowdsecurity/appsec-virtual-patching"
        "crowdsecurity/appsec-generic-rules" "crowdsecurity/appsec-crs-inband"
      ];
    };

    # the house's public address rotates; crowdsec must never ban it
    systemd.services.crowdsec-home-whitelist = lib.mkIf cfg.crowdsecBouncer.enable {
      description = "Keep CrowdSec's whitelist pointed at the house";
      after = [ "podman-crowdsec.service" ];
      requires = [ "podman-crowdsec.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.podman pkgs.curl pkgs.coreutils pkgs.diffutils pkgs.python3 ];
      # no restart: the timer retries, faster retries restart crowdsec
      serviceConfig.Type = "oneshot";
      script = "exec ${pkgs.bash}/bin/bash ${./lib/crowdsec-home-whitelist.sh}";
    };

    # catch ip rotation before anyone notices
    systemd.timers.crowdsec-home-whitelist = lib.mkIf cfg.crowdsecBouncer.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "5min";
        AccuracySec = "30s";
      };
    };

    # the access log is only ever appended to
    services.logrotate.settings.${cfg.accessLog} = {
      frequency = "daily";
      rotate = 7;
      compress = true;
      copytruncate = true;
      missingok = true;
    };

    systemd.services.crowdsec-register-bouncer = lib.mkIf cfg.crowdsecBouncer.enable {
      description = "Register the Traefik bouncer with CrowdSec";
      after = [ "podman-crowdsec.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.podman pkgs.coreutils pkgs.jq ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 15;
      };
      script = ''
        KEY=$(cat ${config.sops.secrets.crowdsec-bouncer-key.path})
        ${retry} 60 5 podman exec crowdsec cscli lapi status
        if podman exec crowdsec cscli bouncers list -o json 2>/dev/null \
             | jq -e '.[]|select(.name=="traefik-bouncer")' >/dev/null; then
          echo "bouncer already registered"
        else
          podman exec crowdsec cscli bouncers add traefik-bouncer -k "$KEY"
        fi
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/traefik 0700 traefik traefik -"
      "d /var/lib/traefik/acme 0700 traefik traefik -"
      # traefik writes access.log, crowdsec reads it
      "d ${logDir} 0755 traefik traefik -"
      "L+ ${config.services.traefik.dataDir}/plugins-local - - - - ${pluginsLocal}"
    ];

    # crowdsec's state regenerates, so it stays on this disk: the most exposed host keeps nothing on a claimable nfs share
    systemd.services.crowdsec-prepare-dirs = lib.mkIf cfg.crowdsecBouncer.enable {
      description = "Write CrowdSec's acquisition, whitelist and rule set config";
      before = [ "podman-crowdsec.service" ];
      requiredBy = [ "podman-crowdsec.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        install -d -m 0755 ${crowdsecDir}/config/acquis.d ${crowdsecDir}/data ${crowdsecDir}/config/appsec-configs
        install -m 0644 ${traefikAcquis} ${crowdsecDir}/config/acquis.d/traefik.yaml
        install -m 0644 ${appsecAcquis} ${crowdsecDir}/config/acquis.d/appsec.yaml
        install -m 0644 ${crsConfig} ${crowdsecDir}/config/appsec-configs/homelab-crs.yaml
        ${lib.optionalString (cfg.crowdsecBouncer.whitelistCidrs != [ ]) ''
          install -d -m 0755 ${crowdsecDir}/config/parsers/s02-enrich
          install -m 0644 ${whitelistParser} ${crowdsecDir}/config/parsers/s02-enrich/homelab-whitelist.yaml
        ''}
      '';
      path = [ pkgs.coreutils ];
    };

    services.traefik = {
      enable = true;
      environmentFiles = [ config.sops.templates."traefik.env".path ];
      staticConfigOptions = {
        log.level = "WARN";
        # read by crowdsec and promtail
        accessLog = {
          filePath = cfg.accessLog;
          format = "json";
          fields.headers.names = {
            "Cf-Ipcountry" = "keep";
            # the client client-ip named, which the limits and the bouncer acted on
            "X-Real-Ip" = "keep";
            "User-Agent" = "keep";
            "Referer" = "keep";
          };
        };
        api.dashboard = true;
        # scraped by vm-105
        metrics.prometheus = {
          entryPoint = "metrics";
          addEntryPointsLabels = true;
          addRoutersLabels = true;
          addServicesLabels = true;
        };
        entryPoints = {
          web = {
            address = ":${toString net.ports.http}";
            http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; };
            transport = { inherit respondingTimeouts; };
          };
          websecure = {
            address = ":${toString net.ports.https}";
            transport = { inherit respondingTimeouts; };
          } // lib.optionalAttrs (trustedHops != [ ]) {
            forwardedHeaders.trustedIPs = trustedHops;
          };
          metrics.address = ":${toString net.ports.traefikMetrics}";
        } // lib.optionalAttrs (anubisRoutes != { }) {
          # anubis' X-Forwarded-For, X-Real-Ip and -Proto carry the client; loopback is the only sender here
          anubis-balancer = {
            address = "${loopback}:${toString anubisBalancerPort}";
            forwardedHeaders.trustedIPs = [ "${loopback}/32" ];
          };
        } // cfg.entryPoints;
        certificatesResolvers.cloudflare.acme = {
          email = config.homelab.acmeEmail;
          storage = "/var/lib/traefik/acme/acme.json";
          dnsChallenge = {
            provider = "cloudflare";
            resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
          };
        };
        experimental.localPlugins = {
          client-ip.moduleName = clientIpPlugin.moduleName;
        } // lib.optionalAttrs cfg.crowdsecBouncer.enable {
          crowdsec-bouncer.moduleName = bouncerPlugin.moduleName;
        };
      };
      dynamicConfigOptions = {
        http = {
          routers = routersWithTls;
          services = cfg.services // routeServices // frontendServices // relayServices // botDefenseServices;
          middlewares = allMiddlewares;
        }
          // lib.optionalAttrs (cfg.serversTransports // relayTransports != { }) {
            serversTransports = cfg.serversTransports // relayTransports;
          };
      };
    };

    # serves robots.txt and llms.txt
    services.nginx = lib.mkIf cfg.botDefense.enable {
      enable = true;
      recommendedGzipSettings = true;
      virtualHosts."wellknown" = {
        listen = [{ addr = loopback; port = wellKnownPort; }];
        locations."/".root = wellKnownRoot;
      };
    };

    systemd.services.iocaine = lib.mkIf cfg.botDefense.enable {
      description = "iocaine: generated nonsense served to AI scrapers";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.iocaine}/bin/iocaine --config-file ${iocaineConfig} start";
        Restart = "always";
        RestartSec = 10;
        DynamicUser = true;
        # only reads the store, answers on loopback
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    # one anubis for every route asking for it: it hands solved requests back to traefik on loopback, which routes them on
    services.anubis.instances = lib.mkIf (anubisRoutes != { }) {
      ingress.settings = {
        BIND = "${loopback}:${toString anubisPort}";
        BIND_NETWORK = "tcp";
        TARGET = "http://${loopback}:${toString anubisBalancerPort}";
        DIFFICULTY = anubisDifficulty;
        METRICS_BIND = "${loopback}:${toString anubisMetricsPort}";
        METRICS_BIND_NETWORK = "tcp";
        # served centrally by botDefense
        SERVE_ROBOTS_TXT = false;
        # the socket peer is always loopback; X-Real-Ip is the client client-ip named
        USE_REMOTE_ADDRESS = false;
        COOKIE_SECURE = true;
        ED25519_PRIVATE_KEY_HEX_FILE = config.sops.secrets.anubis-ed25519-key.path;
      };
    };

    # every instance route reaches its guest through the on-demand proxy, an app route when its app idles
    homelab.onDemand.services = lib.mkIf config.homelab.onDemand.enable (
      lib.mapAttrs (_: r: {
        inherit (r) vmid busyPath;
        targetPort = r.port;
        inherit (lab.instances.${toString r.vmid}.config.idle) wakeAt;
      }) (lib.filterAttrs (_: r: r.vmid != null) cfg.routes)
      // lib.mapAttrs (_: r: let a = catalog.apps.${r.app}; in {
        inherit (r) app busyPath;
        targetPort = r.port;
        manager = "http://${inventory.${a.cluster.manager}.ip}:${toString catalog.swarm.controllerPort}";
        host = lib.head r.nodes;
        idleAfter = a.idle.stopAfter;
        inherit (a.idle) wakeAt;
      }) (lib.filterAttrs (_: r: r.app != null && catalog.apps.${r.app}.idle.stopAfter != null) cfg.routes));

    sops.secrets = {
      cloudflare-token = { };
      # the bouncer plugin reads it inside traefik
      crowdsec-bouncer-key = lib.mkIf cfg.crowdsecBouncer.enable { owner = "traefik"; };
    } // lib.genAttrs basicAuthSecrets (_: { restartUnits = [ "traefik-basic-auth.service" "traefik.service" ]; })
      // lib.optionalAttrs (anubisRoutes != { }) { anubis-ed25519-key = { group = "anubis"; mode = "0440"; }; };
    systemd.services.traefik-basic-auth = lib.mkIf (basicAuthRoutes != { }) {
      description = "Render the basic auth users of traefik's routes";
      before = [ "traefik.service" ];
      requiredBy = [ "traefik.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = baseNameOf basicAuthDir;
        RuntimeDirectoryMode = "0750";
        Group = "traefik";
      };
      script = ''
        set -euo pipefail
        umask 027
      '' + lib.concatStrings (lib.mapAttrsToList (name: r:
        htpasswd.render "${basicAuthDir}/${name}" (lib.mapAttrs (_: secret: config.sops.secrets.${secret}.path) r.basicAuth)
      ) basicAuthRoutes);
    };

    # the metrics entrypoint is for the scraper only (modules/flows.nix guards)
    networking.firewall.allowedTCPPorts = [ net.ports.http net.ports.https net.ports.traefikMetrics ];
    homelab.ingressOnly.ports = [ net.ports.traefikMetrics ];
  };
}
