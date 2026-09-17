{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.traefik;

  # Cloudflare edge ranges: trusted so Traefik reads the real client IP from
  # XFF (else Anubis re-challenges every request and CrowdSec bans the edge).
  cloudflareRanges = [
    "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22"
    "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20"
    "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
    "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
  ];

  # response-header hardening on every websecure route (opt out via noSecureHeaders).
  secureHeadersMiddleware = {
    secure-headers.headers = {
      stsSeconds = 31536000;
      stsIncludeSubdomains = true;
      stsPreload = true;
      contentTypeNosniff = true;
      browserXssFilter = true;
      frameDeny = true;
      referrerPolicy = "strict-origin-when-cross-origin";
    };
  };

  # per-source-IP DoS limits on every websecure route (depth=1 reads the real
  # client from XFF, not the Cloudflare edge).
  rateLimitAverage = 50;   # requests/second sustained per source IP
  rateLimitBurst = 100;    # short spikes allowed above the average
  inFlightAmount = 100;    # concurrent in-flight requests per source IP

  limitMiddlewares = {
    rate-limit.rateLimit = {
      average = rateLimitAverage;
      burst = rateLimitBurst;
      period = "1s";
      sourceCriterion.ipStrategy.depth = 1;
    };
    inflight-limit.inFlightReq = {
      amount = inFlightAmount;
      sourceCriterion.ipStrategy.depth = 1;
    };
  };

  # CrowdSec bouncer plugin. LAPI key from a file (not the Nix store); "live"
  # mode fails open so a crowdsec hiccup can't take the ingress down.
  mkBouncer = appsec: {
    plugin.crowdsec-bouncer = {
      enabled = true;
      crowdsecMode = "live";
      crowdsecLapiScheme = "http";
      crowdsecLapiHost = "127.0.0.1:8180";
      crowdsecLapiKeyFile = config.sops.secrets.crowdsec-bouncer-key.path;
      crowdsecAppsecEnabled = appsec;
      crowdsecAppsecHost = "127.0.0.1:7422";
      # trust the router/Cloudflare hop so the plugin bans the real client IP
      # from X-Forwarded-For, not the proxy in front of it.
      forwardedHeadersTrustedIPs = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
    };
  };

  # default bouncer (IP rep + optional WAF) plus a "-noappsec" variant (IP rep
  # only) for routes the WAF would break (headscale, ntfy).
  bouncerMiddleware = lib.optionalAttrs cfg.crowdsecBouncer.enable ({
    crowdsec = mkBouncer cfg.crowdsecBouncer.appsec;
  } // lib.optionalAttrs cfg.crowdsecBouncer.appsec {
    crowdsec-noappsec = mkBouncer false;
  });

  # default middleware chain prepended to every websecure router, in order:
  # bouncer first (drop known-bad IPs before any work), then per-IP limits, then
  # response-header hardening. Route-specific middlewares (auth, etc.) follow.
  defaultMiddlewares =
    lib.optional cfg.crowdsecBouncer.enable "crowdsec"
    ++ [ "rate-limit" "inflight-limit" "secure-headers" ];

  # ensure every websecure route has tls.certResolver = "cloudflare" unless
  # overridden, and prepend the default middleware chain unless opted out.
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
      wantsDefaults = needsTls && !(builtins.elem name cfg.noSecureHeaders);
      # routes opted out of AppSec use the WAF-free bouncer variant but keep
      # every other default middleware (IP bouncer, rate limits, headers).
      chain =
        if cfg.crowdsecBouncer.enable
           && cfg.crowdsecBouncer.appsec
           && builtins.elem name cfg.crowdsecBouncer.noAppsecRouters
        then map (m: if m == "crowdsec" then "crowdsec-noappsec" else m) defaultMiddlewares
        else defaultMiddlewares;
    in
    if wantsDefaults then
      withTls // { middlewares = chain ++ (withTls.middlewares or []); }
    else
      withTls
  ) cfg.routers;
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

    noSecureHeaders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Router names that should NOT get the secure-headers middleware.";
    };

    crowdsecBouncer = {
      enable = lib.mkEnableOption ''
        the CrowdSec bouncer as a Traefik plugin middleware on every route.
        CrowdSec already parses the access logs; this turns its decisions into
        actual blocks (community blocklist + local bans) instead of only logging'';

      appsec = lib.mkEnableOption ''
        the CrowdSec AppSec (WAF) component: inline request inspection with
        OWASP-CRS-compatible rules, in addition to IP reputation blocking'';

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
            difficulty = lib.mkOption {
              type = lib.types.int;
              default = 4;
              description = "Proof-of-work difficulty in leading zero bits. Higher = more client CPU.";
            };
          };
        });
        default = {};
        description = "Anubis bot-filter instances keyed by name.";
      };
    };

    trustCloudflare = lib.mkEnableOption ''
      trusting Cloudflare edge ranges on the websecure entrypoint so the real
      client IP (not the rotating edge IP) reaches the backends: required for
      Anubis and CrowdSec to work correctly behind proxied Cloudflare DNS'';

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "WARN";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare-token = {};
    # readable by the traefik user because the bouncer plugin (running inside
    # traefik) reads the LAPI key from this file.
    sops.secrets.crowdsec-bouncer-key = lib.mkIf cfg.crowdsecBouncer.enable {
      owner = "traefik";
    };
    sops.templates."traefik.env".content = ''
      CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-token}
    '';

    virtualisation.oci-containers.containers.crowdsec = {
      image = "crowdsecurity/crowdsec:latest";
      volumes = [
        "/var/lib/crowdsec/config:/etc/crowdsec"
        "/var/lib/crowdsec/data:/var/lib/crowdsec/data"
        "/var/log/traefik:/var/log/traefik:ro"
      ]
      # AppSec acquisition config tells crowdsec to listen for inline request
      # inspection on :7422, which the bouncer plugin forwards requests to.
      ++ lib.optional cfg.crowdsecBouncer.appsec
        "/var/lib/crowdsec/acquis-appsec.yaml:/etc/crowdsec/acquis.d/appsec.yaml:ro";
      ports = [ "127.0.0.1:8180:8080" ]
        ++ lib.optional cfg.crowdsecBouncer.appsec "127.0.0.1:7422:7422";
      environment = {
        COLLECTIONS = "crowdsecurity/traefik crowdsecurity/http-cve"
          + lib.optionalString cfg.crowdsecBouncer.appsec
            " crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules";
      };
    };

    # register the bouncer with CrowdSec's local API using the shared key, so the
    # plugin authenticates. Idempotent: skip if the bouncer already exists.
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
        # wait for the LAPI to answer.
        for i in $(seq 1 60); do
          podman exec crowdsec cscli lapi status >/dev/null 2>&1 && break
          sleep 5
        done
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
        ${pkgs.coreutils}/bin/printf 'source: appsec\nlisten_addr: 0.0.0.0:7422\nappsec_config: crowdsecurity/appsec-default\nlabels:\n  type: appsec\n' \
          > /var/lib/crowdsec/acquis-appsec.yaml
      '';
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/traefik 0700 traefik traefik -"
      "d /var/lib/traefik/acme 0700 traefik traefik -"
      # traefik (not root) writes access.log here; the crowdsec container reads
      # it. root-owned 0750 blocked the write, so the access log never appeared
      # and crowdsec had nothing to parse.
      "d /var/log/traefik 0755 traefik traefik -"
    ];

    # /var/lib/crowdsec is an NFS automount; create its subdirs here (tmpfiles
    # runs before the mount triggers, so the container would fail on statfs).
    systemd.services.crowdsec-prepare-dirs = {
      description = "Create CrowdSec config/data dirs on the NFS share";
      before = [ "podman-crowdsec.service" ];
      requiredBy = [ "podman-crowdsec.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p /var/lib/crowdsec/config/acquis.d /var/lib/crowdsec/data
        # tell CrowdSec to read the Traefik access log so its traefik/http-cve
        # scenarios fire on real traffic. The path is inside the container
        # (the log dir is bind-mounted there). printf, not a heredoc, so Nix
        # string de-indentation cannot corrupt the YAML.
        ${pkgs.coreutils}/bin/printf 'source: file\nfilenames:\n  - /var/log/traefik/access.log\nlabels:\n  type: traefik\n' \
          > /var/lib/crowdsec/config/acquis.d/traefik.yaml
        ${lib.optionalString (cfg.crowdsecBouncer.whitelistCidrs != []) ''
          # whitelist parser: CrowdSec never bans these CIDRs.
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

    # acme.json lives on the 0777 NFS share; lego drops the cloudflare resolver
    # if it's more permissive than 0600, so tighten it on every start.
    systemd.services.traefik.preStart = ''
      f=/var/lib/traefik/acme/acme.json
      if [ -e "$f" ]; then
        ${pkgs.coreutils}/bin/chmod 600 "$f"
      fi
    '';

    services.traefik = {
      enable = true;
      environmentFiles = [ config.sops.templates."traefik.env".path ];
      staticConfigOptions = {
        log.level = cfg.logLevel;
        # JSON access log to a file: CrowdSec parses it, and promtail ships it to
        # Loki. Keep Cf-Ipcountry so the Grafana world map can plot request
        # origins (Cloudflare sets it on every proxied request).
        accessLog = {
          filePath = "/var/log/traefik/access.log";
          format = "json";
          fields.headers.names."Cf-Ipcountry" = "keep";
        };
        api.dashboard = true;
        # Prometheus metrics on a dedicated entrypoint (:8082), scraped by
        # vm-104. Per-entrypoint/router/service labels drive the HTTP analytics
        # dashboard (request rate, status codes, latency percentiles) with a
        # service filter. Loopback+LAN only; not exposed publicly.
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
            # bound how long a client may take to send a request: a client that
            # dribbles headers forever (Slowloris) is dropped instead of holding
            # a connection. writeTimeout is 0 (unbounded) so large media
            # downloads/streams are not cut off.
            transport.respondingTimeouts = { readTimeout = "120s"; writeTimeout = "0s"; idleTimeout = "180s"; };
          };
          websecure = {
            address = ":443";
            transport.respondingTimeouts = { readTimeout = "120s"; writeTimeout = "0s"; idleTimeout = "180s"; };
          } // lib.optionalAttrs cfg.trustCloudflare {
            forwardedHeaders.trustedIPs =
              cloudflareRanges ++ [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
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
      # only present when the bouncer is enabled: an empty `experimental` block
      # makes Traefik fail to start ("experimental cannot be a standalone
      # element"). Traefik downloads and caches the plugin at startup.
      // lib.optionalAttrs cfg.crowdsecBouncer.enable {
        experimental.plugins.crowdsec-bouncer = {
          moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin";
          version = "v1.4.5";
        };
      };
      dynamicConfigOptions = {
        http = {
          routers = routersWithTls;
          services = cfg.services;
          middlewares = cfg.middlewares // secureHeadersMiddleware // limitMiddlewares // bouncerMiddleware;
        }
          // lib.optionalAttrs (cfg.serversTransports != {}) { serversTransports = cfg.serversTransports; };
      } // lib.optionalAttrs (cfg.tcp != {}) { tcp = cfg.tcp; };
    };

    # Anubis instances: one per browser-facing upstream, each bound to loopback.
    # the default baked-in bot policy (challenge Mozilla UAs, allow well-known /
    # robots / API-JSON) is sufficient; only the bind, target and difficulty vary.
    services.anubis.instances = lib.mkIf cfg.anubis.enable (lib.mapAttrs (_name: a: {
      settings = {
        BIND = "127.0.0.1:${toString a.listenPort}";
        BIND_NETWORK = "tcp";
        TARGET = a.upstream;
        DIFFICULTY = a.difficulty;
        # unique loopback metrics port per instance; Prometheus can scrape later.
        METRICS_BIND = "127.0.0.1:${toString (a.listenPort + 1000)}";
        METRICS_BIND_NETWORK = "tcp";
        SERVE_ROBOTS_TXT = true;
      };
    }) cfg.anubis.instances);

    # 8082 = Prometheus metrics, scraped by vm-104. Not port-forwarded, so it
    # stays on the LAN/DMZ; the internet never reaches it.
    networking.firewall.allowedTCPPorts = [ 80 443 8082 ];
  };
}
