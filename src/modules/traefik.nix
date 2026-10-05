{ config, lib, pkgs, retry, ... }:
let
  cfg = config.homelab.traefik;

  # cloudflare edge: trusted for real client ip
  cloudflareRanges = [
    "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
    "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
    "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
    "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
  ];

  # lan, dmz and wireguard mesh
  privateNetworks = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
  privateRanges = privateNetworks ++ [ "127.0.0.1/32" ];

  # loopback ports of the bot defence: iocaine's labyrinth and the nginx serving robots.txt and llms.txt
  iocainePort = 42069;
  wellKnownPort = 8083;

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
  # what forwardauth and apps read as the request's target; dropped on every traefik, whoever sent them. A trusted
  # X-Forwarded-Host once let a client name auth.lsck0.dev, hit its bypass rule and reach any gated app.
  # X-Forwarded-For/-Proto and X-Real-Ip stay: the entrypoint keeps them only from trustedProxies and cloudflare.
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

  # per-source-ip dos limits
  rateLimitAverage = 50;   # req/s sustained
  rateLimitBurst = 100;    # spikes above average
  inFlightAmount = 100;    # concurrent requests

  # not xff depth: the entrypoint drops an untrusted sender's xff and depth then keys all of them as ""
  remoteSource.requestHeaderName = "X-Real-Ip";
  # cloudflare appends the client to xff and passes a forged x-real-ip through
  cloudflareSource.ipStrategy.excludedIPs = cloudflareRanges;

  mkLimitMiddlewares = suffix: sourceCriterion: {
    "rate-limit${suffix}".rateLimit = {
      average = rateLimitAverage;
      burst = rateLimitBurst;
      period = "1s";
      inherit sourceCriterion;
    };
    "inflight-limit${suffix}".inFlightReq = {
      amount = inFlightAmount;
      inherit sourceCriterion;
    };
  };

  limitMiddlewares = mkLimitMiddlewares "" remoteSource
    // lib.optionalAttrs cfg.cloudflareOnly.enable (mkLimitMiddlewares "-cloudflare" cloudflareSource)
    // {
    # retry requests that never reached the backend
    retry-upstream.retry = {
      attempts = 4;
      initialInterval = "500ms";
    };
    # answers 403 to everyone: paths a route must never serve, like an app's own metrics
    deny-all.ipAllowList.sourceRange = [ "255.255.255.255/32" ];
  } // lib.optionalAttrs cfg.cloudflareOnly.enable {
    # proxying only protects if the origin refuses others
    cloudflare-only.ipAllowList.sourceRange = cloudflareRanges ++ privateRanges;
  } // lib.listToAttrs (map (bytes: lib.nameValuePair "body-limit-${toString bytes}" {
    buffering = {
      maxRequestBodyBytes = bytes;
      # spill to disk past 1 mib
      memRequestBodyBytes = 1048576;
      maxResponseBodyBytes = 0;
    };
  }) (lib.unique (lib.attrValues cfg.bodyLimits)));

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
  # a second appsec listener that adds the owasp core rule set, for the routers in crsRouters
  appsecCrsPort = 7423;
  crs = cfg.crowdsecBouncer.appsec && cfg.crowdsecBouncer.crsRouters != [ ];

  # the hub's blocking crs, minus its anomaly verdict (949110) on anubis' own challenge endpoints, which
  # trip it with their proof-of-work payload; webapp-template's modsecurity carried the same exclusion
  crsConfig = pkgs.writeText "homelab-crs.yaml" ''
    name: homelab/crs-inband
    default_remediation: ban
    inband_rules:
     - crowdsecurity/crs
    pre_eval:
     - filter: IsInBand == true && req.URL.Path startsWith "/.within.website/"
       apply:
        - RemoveInBandRuleByID(949110)
  '';

  mkBouncer = appsec: appsecHostPort: {
    plugin.crowdsec-bouncer = {
      enabled = true;
      crowdsecMode = "live";
      crowdsecLapiScheme = "http";
      crowdsecLapiHost = "127.0.0.1:8180";
      crowdsecLapiKeyFile = config.sops.secrets.crowdsec-bouncer-key.path;
      crowdsecAppsecEnabled = appsec;
      crowdsecAppsecHost = "127.0.0.1:${toString appsecHostPort}";
      # so the plugin bans the real client ip
      forwardedHeadersTrustedIPs = privateNetworks ++ lib.optionals cfg.trustCloudflare cloudflareRanges;
    };
  };

  # default bouncer plus an ip-rep-only noappsec variant
  bouncerMiddleware = lib.optionalAttrs cfg.crowdsecBouncer.enable ({
    crowdsec = mkBouncer cfg.crowdsecBouncer.appsec appsecPort;
  } // lib.optionalAttrs cfg.crowdsecBouncer.appsec {
    crowdsec-noappsec = mkBouncer false appsecPort;
  } // lib.optionalAttrs crs {
    crowdsec-crs = mkBouncer true appsecCrsPort;
  });

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
    bind = ["127.0.0.1:${toString iocainePort}"]

    [sources]
    markov = ["${corpus}"]
    words = "${wordList}"
  '';

  labyrinthRule = "HeaderRegexp(`User-Agent`, `(?i).*(${lib.concatStringsSep "|" labyrinthUserAgents}).*`)"
    # cloudflare workers fetch on someone else's behalf; no visitor arrives through one
    + " || HeaderRegexp(`Cf-Worker`, `.+`)";

  honeypotRule = lib.concatMapStringsSep " || " (p: "Path(`${p}`)") honeypotPaths;

  botDefenseRouters = lib.optionalAttrs cfg.botDefense.enable {
    # every host, above all routes, no auth in front
    wellknown-tls = {
      rule = "Path(`/robots.txt`) || Path(`/llms.txt`) || Path(`/.well-known/llms.txt`)";
      service = "wellknown";
      entryPoints = [ "websecure" ];
      priority = 10000;
    };
    labyrinth-tls = {
      rule = labyrinthRule;
      service = "labyrinth";
      entryPoints = [ "websecure" ];
      priority = 9000;
    };
    # above real routes, below robots.txt
    honeypot-tls = {
      rule = honeypotRule;
      service = "labyrinth";
      entryPoints = [ "websecure" ];
      priority = 9500;
    };
  };

  botDefenseServices = lib.optionalAttrs cfg.botDefense.enable {
    wellknown.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString wellKnownPort}"; }];
    labyrinth.loadBalancer.servers = [{ url = "http://127.0.0.1:${toString iocainePort}"; }];
  };

  # prepended to every websecure router; the strip runs before a router's own authelia sets the identity
  defaultMiddlewares =
    [ "strip-client-headers" ]
    ++ lib.optional cfg.crowdsecBouncer.enable "crowdsec"
    ++ [ "rate-limit" "inflight-limit" "retry-upstream" "secure-headers" ];

  # default websecure certResolver to cloudflare
  routersWithTls = lib.mapAttrs (name: router:
    let
      eps = router.entryPoints or [];
      needsTls = builtins.elem "websecure" eps;
      hasCertResolver = (router ? tls) && (router.tls ? certResolver);
      withTls =
        if needsTls && !hasCertResolver then
          router // { tls = (router.tls or {}) // { certResolver = "cloudflare"; }; }
        else
          router;
      sameOriginFrames = builtins.elem name cfg.sameOriginFrameRouters;
      crsSwap = m: if crs && m == "crowdsec" && builtins.elem name cfg.crowdsecBouncer.crsRouters then "crowdsec-crs" else m;
      noReferrer = builtins.elem name cfg.noReferrerRouters;
      frameSwap = m:
        if sameOriginFrames && m == "secure-headers" then "secure-headers-sameorigin"
        else if noReferrer && m == "secure-headers" then "secure-headers-noreferrer"
        else m;
      cloudflareOnly = cfg.cloudflareOnly.enable && !(builtins.elem name cfg.cloudflareOnly.exemptRouters);
      # only cloudflare and private sources pass cloudflare-only, so key by the client cloudflare saw
      limitSwap = m:
        if cloudflareOnly && (m == "rate-limit" || m == "inflight-limit") then "${m}-cloudflare" else m;
      # noappsec routes swap in the waf-free bouncer, crs routers the one with the core rule set
      chain = map (m: crsSwap (limitSwap (frameSwap m))) (
        (if cfg.crowdsecBouncer.enable
            && cfg.crowdsecBouncer.appsec
            && (builtins.elem name cfg.crowdsecBouncer.noAppsecRouters
                # so scanners reach the labyrinth
                || name == "honeypot-tls")
         then map (m: if m == "crowdsec" then "crowdsec-noappsec" else m) defaultMiddlewares
         else defaultMiddlewares)
        ++ lib.optional (cfg.bodyLimits ? ${name}) "body-limit-${toString cfg.bodyLimits.${name}}"
        ++ lib.optional cloudflareOnly "cloudflare-only");
    in
    if needsTls then
      withTls // { middlewares = chain ++ (withTls.middlewares or []); }
    else
      withTls
  ) (cfg.routers // botDefenseRouters);
in {
  options.homelab.traefik = {
    enable = lib.mkEnableOption "Traefik reverse proxy with ACME and CrowdSec";

    entryPoints = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional entryPoints beyond web/websecure.";
    };

    routers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP routers.";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP services.";
    };

    tcp = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik TCP config (routers + services).";
    };

    sameOriginFrameRouters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Routers that get X-Frame-Options: SAMEORIGIN instead of DENY, for apps
        that legitimately frame their own pages. Everything else keeps DENY.
      '';
    };

    noReferrerRouters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Routers whose pages send no Referer at all, for apps whose urls carry private input.";
    };

    middlewares = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik HTTP middlewares.";
    };

    serversTransports = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Traefik servers transports.";
    };

    cloudflareOnly = {
      enable = lib.mkEnableOption ''
        refusing requests that did not arrive through Cloudflare on every
        websecure router except those in exemptRouters. LAN, DMZ and WireGuard
        are always allowed, so this cannot lock you out from inside'';

      exemptRouters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Routers that must stay reachable directly: every host whose DNS record
          is not proxied (see `proxied` in modules/routes.nix). Restricting one
          of those would take it off the internet entirely, since nothing
          forwards it through the edge.
        '';
      };
    };

    bodyLimits = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      example = { searxng-tls = 33554432; };
      description = ''
        Router name to its maximum request body in bytes.

        Traefik can only enforce a body cap by buffering the request, which
        would stall large uploads, so this is never in the default chain: name
        the routes that should carry it.
      '';
    };

    botDefense = {
      enable = lib.mkEnableOption ''
        robots.txt and llms.txt on every host, plus the iocaine labyrinth for
        crawlers that ignore them: a matching user agent is served endless
        generated prose instead of the real backend'';
    };

    crowdsecBouncer = {
      enable = lib.mkEnableOption ''
        CrowdSec parsing the access logs, plus its bouncer as a Traefik plugin
        middleware on every route that turns its decisions into actual blocks
        (community blocklist + local bans)'';

      appsec = lib.mkEnableOption ''
        the CrowdSec AppSec (WAF) component: inline request inspection with
        OWASP-CRS-compatible rules, in addition to IP reputation blocking'';

      crsRouters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Router names whose AppSec inspection adds the OWASP Core Rule Set in blocking mode, on a listener of its
          own: the CRS misreads plenty of ordinary app traffic, so it applies only where an app was built for it.
        '';
      };

      noAppsecRouters = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Router names that keep the IP bouncer but skip AppSec/WAF inspection
          (e.g. non-browser APIs the OWASP rules would break). Only meaningful
          when appsec is enabled.
        '';
      };

      whitelistCidrs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          CIDRs CrowdSec never bans (a whitelist parser). Use for the LAN and
          your own home network so legit browsing can't self-ban. NOTE: a
          dynamic ISP IPv6 prefix here may rotate and need updating.
        '';
      };
    };

    anubis = {
      enable = lib.mkEnableOption ''
        Anubis proof-of-work bot filter in front of browser-facing routes.
        Each instance sits between Traefik and one upstream: a real browser
        solves a JS challenge once, headless scrapers and AI crawlers that
        ignore it are dropped. Point the route's Traefik service at the
        instance's listenPort instead of the upstream'';

      instances = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            upstream = lib.mkOption {
              type = lib.types.str;
              description = "Backend URL Anubis forwards solved requests to (may itself be an on-demand proxy port).";
            };
            listenPort = lib.mkOption {
              type = lib.types.port;
              description = "127.0.0.1 port Anubis binds. Point the Traefik service here.";
            };
          };
        });
        default = {};
        description = "Anubis bot-filter instances keyed by name.";
      };
    };

    authelia.address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://10.100.0.101:9091/api/authz/forward-auth";
      description = ''
        Authelia's forward-auth endpoint. Set, it defines the `authelia` middleware for routers to list. It
        never trusts a client's X-Forwarded-* and hands only Authelia's own Remote-* headers to the app.
      '';
    };

    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.200.0.200/32" ];
      description = ''
        Sources whose X-Forwarded-* and X-Real-Ip headers the websecure entrypoint keeps: another Traefik
        relaying to this one. Without it every relayed request looks like it came from the relay, and the
        per-client rate and in-flight limits share one bucket for all of them.
      '';
    };

    trustCloudflare = lib.mkEnableOption ''
      trusting Cloudflare edge ranges on the websecure entrypoint so the real
      client IP (not the rotating edge IP) reaches the backends: required for
      Anubis and CrowdSec to work correctly behind proxied Cloudflare DNS'';
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare-token = {};
    # the bouncer plugin reads it inside traefik
    sops.secrets.crowdsec-bouncer-key = lib.mkIf cfg.crowdsecBouncer.enable {
      owner = "traefik";
    };
    sops.templates."traefik.env".content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
    '';

    virtualisation.oci-containers.containers.crowdsec = {
      image = "crowdsecurity/crowdsec:v1.7.7";
      volumes = [
        "/var/lib/crowdsec/config:/etc/crowdsec"
        "/var/lib/crowdsec/data:/var/lib/crowdsec/data"
        "/var/log/traefik:/var/log/traefik:ro"
      ]
      # appsec acquisition for inline inspection
      ++ lib.optional cfg.crowdsecBouncer.appsec
        "/var/lib/crowdsec/acquis-appsec.yaml:/etc/crowdsec/acquis.d/appsec.yaml:ro";
      ports = [ "127.0.0.1:8180:8080" ]
        ++ lib.optional cfg.crowdsecBouncer.appsec "127.0.0.1:${toString appsecPort}:${toString appsecPort}"
        ++ lib.optional crs "127.0.0.1:${toString appsecCrsPort}:${toString appsecCrsPort}";
      environment = {
        COLLECTIONS = "crowdsecurity/traefik crowdsecurity/http-cve"
          + lib.optionalString cfg.crowdsecBouncer.appsec
            " crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
          + lib.optionalString crs " crowdsecurity/appsec-crs-inband";
      };
    };

    # crowdsec once banned the house; keep it whitelisted
    systemd.services.crowdsec-home-whitelist = lib.mkIf cfg.crowdsecBouncer.enable {
      description = "Keep CrowdSec's whitelist pointed at the house";
      after = [ "podman-crowdsec.service" ];
      requires = [ "podman-crowdsec.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.podman pkgs.curl pkgs.coreutils pkgs.gawk ];
      # no restart: the timer retries, faster retries used to restart crowdsec
      serviceConfig.Type = "oneshot";
      script = "exec ${pkgs.bash}/bin/bash ${../scripts/crowdsec-home-whitelist.sh}";
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
    services.logrotate.settings."/var/log/traefik/access.log" = {
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

    systemd.services.crowdsec-appsec-acquis = lib.mkIf cfg.crowdsecBouncer.appsec {
      description = "Write CrowdSec AppSec acquisition config";
      before = [ "podman-crowdsec.service" ];
      requiredBy = [ "podman-crowdsec.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${pkgs.coreutils}/bin/printf 'source: appsec\nlisten_addr: 0.0.0.0:${toString appsecPort}\nappsec_config: crowdsecurity/appsec-default\nlabels:\n  type: appsec\n' \
          > /var/lib/crowdsec/acquis-appsec.yaml
        ${lib.optionalString crs ''
          ${pkgs.coreutils}/bin/printf -- '---\nsource: appsec\nname: appsec-crs\nlisten_addr: 0.0.0.0:${toString appsecCrsPort}\nappsec_configs:\n  - crowdsecurity/appsec-default\n  - homelab/crs-inband\nlabels:\n  type: appsec\n' \
            >> /var/lib/crowdsec/acquis-appsec.yaml
        ''}
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/traefik 0700 traefik traefik -"
      "d /var/lib/traefik/acme 0700 traefik traefik -"
      # traefik writes access.log, crowdsec reads it
      "d /var/log/traefik 0755 traefik traefik -"
    ];

    # nfs automount; create subdirs here
    systemd.services.crowdsec-prepare-dirs = {
      description = "Create CrowdSec config/data dirs on the NFS share";
      before = [ "podman-crowdsec.service" ];
      requiredBy = [ "podman-crowdsec.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/crowdsec/config/acquis.d /var/lib/crowdsec/data
        ${lib.optionalString crs ''
          ${pkgs.coreutils}/bin/mkdir -p /var/lib/crowdsec/config/appsec-configs
          ${pkgs.coreutils}/bin/install -m 0644 ${crsConfig} /var/lib/crowdsec/config/appsec-configs/homelab-crs.yaml
        ''}
        # printf, not heredoc: nix de-indent breaks yaml
        ${pkgs.coreutils}/bin/printf 'source: file\nfilenames:\n  - /var/log/traefik/access.log\nlabels:\n  type: traefik\n' \
          > /var/lib/crowdsec/config/acquis.d/traefik.yaml
        ${lib.optionalString (cfg.crowdsecBouncer.whitelistCidrs != []) ''
          # crowdsec never bans these cidrs
          ${pkgs.coreutils}/bin/mkdir -p /var/lib/crowdsec/config/parsers/s02-enrich
          ${pkgs.coreutils}/bin/printf '%s\n' \
            'name: homelab/whitelist' \
            'description: homelab trusted networks' \
            'whitelist:' \
            '  reason: homelab trusted networks' \
            '  cidr:' \
            ${lib.concatMapStringsSep " " (c: "'    - \"${c}\"'") cfg.crowdsecBouncer.whitelistCidrs} \
            > /var/lib/crowdsec/config/parsers/s02-enrich/homelab-whitelist.yaml
        ''}
      '';
    };

    # lego wants acme.json 600 on the 0777 share; without it traefik serves its default cert, so wait for the nas
    systemd.services.traefik.preStart = ''
      f=/var/lib/traefik/acme/acme.json
      for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
        [ -e "$f" ] && break
        ${pkgs.coreutils}/bin/sleep 5
      done
      if [ -e "$f" ]; then
        ${pkgs.coreutils}/bin/chmod 600 "$f"
      fi
    '';
    systemd.services.traefik.serviceConfig.TimeoutStartSec = "15min";

    services.traefik = {
      enable = true;
      environmentFiles = [ config.sops.templates."traefik.env".path ];
      staticConfigOptions = {
        log.level = "WARN";
        # read by crowdsec and promtail
        accessLog = {
          filePath = "/var/log/traefik/access.log";
          format = "json";
          fields.headers.names = {
            "Cf-Ipcountry" = "keep";
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
            address = ":80";
            http.redirections.entryPoint = { to = "websecure"; scheme = "https"; permanent = true; };
            # bound slow-dribbling clients
            transport.respondingTimeouts = { readTimeout = "120s"; writeTimeout = "0s"; idleTimeout = "180s"; };
          };
          websecure = {
            address = ":443";
            transport.respondingTimeouts = { readTimeout = "120s"; writeTimeout = "0s"; idleTimeout = "180s"; };
          } // lib.optionalAttrs (cfg.trustCloudflare || cfg.trustedProxies != [ ]) {
            forwardedHeaders.trustedIPs = cfg.trustedProxies
              ++ lib.optionals cfg.trustCloudflare (cloudflareRanges ++ privateNetworks);
          };
          metrics.address = ":8082";
        } // cfg.entryPoints;
        certificatesResolvers.cloudflare.acme = {
          email = config.homelab.acmeEmail;
          storage = "/var/lib/traefik/acme/acme.json";
          dnsChallenge = {
            provider = "cloudflare";
            resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
          };
        };
      }
      # an empty experimental block breaks traefik
      // lib.optionalAttrs cfg.crowdsecBouncer.enable {
        experimental.plugins.crowdsec-bouncer = {
          moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin";
          version = "v1.4.5";
        };
      };
      dynamicConfigOptions = {
        http = {
          routers = routersWithTls;
          services = cfg.services // botDefenseServices;
          middlewares = cfg.middlewares // secureHeadersMiddleware // limitMiddlewares // bouncerMiddleware
            // stripClientHeadersMiddleware // autheliaMiddleware;
        }
          // lib.optionalAttrs (cfg.serversTransports != {}) { serversTransports = cfg.serversTransports; };
      } // lib.optionalAttrs (cfg.tcp != {}) { tcp = cfg.tcp; };
    };

    # serves robots.txt and llms.txt
    services.nginx = lib.mkIf cfg.botDefense.enable {
      enable = true;
      recommendedGzipSettings = true;
      virtualHosts."wellknown" = {
        listen = [{ addr = "127.0.0.1"; port = wellKnownPort; }];
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

    # one per browser-facing upstream
    services.anubis.instances = lib.mkIf cfg.anubis.enable (lib.mapAttrs (_name: a: {
      settings = {
        BIND = "127.0.0.1:${toString a.listenPort}";
        BIND_NETWORK = "tcp";
        TARGET = a.upstream;
        DIFFICULTY = anubisDifficulty;
        # unique loopback metrics port per instance
        METRICS_BIND = "127.0.0.1:${toString (a.listenPort + 1000)}";
        METRICS_BIND_NETWORK = "tcp";
        # served centrally by botDefense
        SERVE_ROBOTS_TXT = false;

        # socket peer is always loopback
        USE_REMOTE_ADDRESS = false;

        # no COOKIE_DOMAIN: instances on one apex overwrite each other's cookies and challenge forever
        COOKIE_SECURE = true;

        # shared key so clearance spans instances
        ED25519_PRIVATE_KEY_HEX_FILE = config.sops.secrets.anubis-ed25519-key.path;
      };
    }) cfg.anubis.instances);

    # dynamicuser instances share the anubis group
    sops.secrets.anubis-ed25519-key = lib.mkIf cfg.anubis.enable {
      group = "anubis";
      mode = "0440";
    };

    # 8082: prometheus metrics, for the scraper only
    networking.firewall.allowedTCPPorts = [ 80 443 8082 ];
    homelab.ingressOnly.ports = [ 8082 ];
  };
}
