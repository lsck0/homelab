# the properties of one deployed service, shared by an instance's services (instance.nix `services`) and a swarm
# app's routes (app.nix `routes`): where it is exposed, how the ingress protects it, what telemetry it gets
#
# Every feature is off unless the service opts in: `on = [ "<feature>" ... ];`, usually named lists of
# modules/profiles.nix concatenated. A service without `on` is a plain route to its port: no sso, no defences, no
# card, no probe, no telemetry, no guard on the port. The ingresses (modules/traefik), authelia, lldap, the
# homepage, the prober and the router derive everything from these records; none keeps a per-service list.
#
#   services.git = {
#     port = 80;
#     # logs in itself through authelia oidc; git clients push packs the waf rules misread
#     on = lib.subtractLists [ "sso" "waf" ] (profiles.hardenedInternal ++ profiles.listed ++ profiles.observed);
#   };
#
# Protection per path: a second service (or app route) on the same host and port with its own `path` and `on`; the
# ingress routes the longer prefix first, `/api` rate limited while `/` stays plain.
#
# Composition (featureProblemsOf, an evaluation error each): sso and anubis both stop bots before the app, so a route
# takes one. A route of the external zone is public by definition, its name on the internet whatever it takes: sso
# cannot run there (the dmz reaches no authelia), internet has nothing to add. A public route of the internal zone may still put prefixes of itself behind authelia,
# `ssoPaths = [ "/metrics" ];`: the internal ingress sends them through authelia ahead of every other router of the
# route, and authelia admits them like a route behind sso (admins and the route's own group). waf, captcha,
# anonymousLimit and tarpit act through the gate that crowdsec puts in front of a route, so they need crowdsec; the
# gate never stops the house, the lab, wireguard or a user authelia knows, whatever a route says. cloudflare proxies
# the route's public name, which an internal route has with `internet` alone. An onion route's onion routers pass the gate whatever its
# `on` takes for its name (modules/traefik). houseUnlimited gives the house, wireguard and the internal zone a router
# of the route's own with none of its limits, gate, proof of work or body limit, whoever else it protects; it takes no
# `sources`, which name a route's clients alone.
{ lib }:
let
  inherit (lib) mkOption types;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # what the ingress does for a route
  protectionFeatures = [
    "sso" "anubis" "waf" "crowdsec" "rateLimit" "inflightLimit" "bodyLimit" "botDefense" "secureHeaders" "accessLog"
    # the gate (modules/traefik/lib/gate) asks a client crowdsec flagged its captcha; without, captcha decisions pass
    "captcha"
    # the gate's token bucket for clients without an authelia session, below rateLimit's for everyone
    "anonymousLimit"
    # a banned client waits for its ban page; on the bot defence's own routers, the labyrinth trickles
    "tarpit"
    # the dns record goes through cloudflare's proxy and the origin refuses anyone else
    "cloudflare"
    # an internal route is relayed by the edge, so it is reachable from the internet behind authelia (internal only)
    "internet"
    # the backend port answers its zone's ingress and the instance's grants only (modules/network.nix)
    "guard"
    "probe"
    "homepage"
  ];
  # what acts through the gate crowdsec puts in front of a route
  crowdsecFeatures = [ "waf" "captcha" "anonymousLimit" "tarpit" ];
  # what the ingress spares some clients of a route, which keeps its protection for everyone else (modules/traefik)
  exemptionFeatures = [
    # the house, wireguard and the internal zone pass no limit, gate, proof of work or body limit: a router of their own
    "houseUnlimited"
  ];
  # frontend: the browser's otlp beacons at <host>/otlp, relayed by the ingress to the collector (modules/traefik)
  telemetryFeatures = [ "metrics" "logs" "traces" "profiles" "dashboard" "alerts" "frontend" ];
  # what the platform runs for a swarm app besides its telemetry: sleeping when idle, its card on the dashboard
  platformFeatures = [ "scaleToZero" "homepage" ];
  # what a browser app speaks; anything else matches no router and gets a 404
  webMethods = [ "GET" "HEAD" "POST" "PUT" "PATCH" "DELETE" "OPTIONS" ];
  # webapp-template's request body cap: forms and api calls; an upload route raises it or leaves bodyLimit out
  bodyLimitDefaultBytes = 1024 * 1024;
  # where a web server in a container listens unless its app says otherwise (the lab's own examples do)
  targetPortDefault = 8000;

  dnsLabel = types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
  urlPath = types.strMatching "/.*";
  # a reason: any text with a word in it
  why = types.strMatching ".*[a-z].*";
  # /segment[/segment...] without a trailing slash
  urlSegments = "(/[A-Za-z0-9._~-]+)+";
  # a url prefix: / or segments
  urlPrefix = types.strMatching "/|${urlSegments}";
  serviceName = types.strMatching "[A-Za-z0-9][A-Za-z0-9_.-]*";
  # the router's secret holding an onion route's key (kind onion, scripts/lib/onion.sh)
  onionKeyOf = name: "${name}-onion-key";

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  # the features opted into, each one of `features`
  featuresType = features: types.listOf (types.enum features);

  widgetType = types.submodule {
    options = {
      type = mkOption { type = types.str; description = "The homepage widget type."; };
      url = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The widget's api url; null: the service at its own address plus `path`.";
      };
      path = mkOption { type = types.str; default = ""; description = "Appended to the service's own address when `url` is null."; };
      tokens = mkOption { type = types.attrsOf types.str; default = { }; description = "Widget field -> lab token (modules/tokens)."; };
      secrets = mkOption { type = types.attrsOf types.str; default = { }; description = "Widget field -> sops secret, which the dashboard host reads."; };
      settings = mkOption { type = types.attrs; default = { }; description = "Any other widget field, verbatim."; };
    };
  };
in rec {
  inherit protectionFeatures crowdsecFeatures exemptionFeatures telemetryFeatures platformFeatures webMethods bodyLimitDefaultBytes featuresType urlPath why serviceName onionKeyOf;

  # the dashboard card; a deployment's defaults name its kind (an instance service, an app)
  cardType = { name, group, icon, description }: types.submodule {
    options = {
      group = mkOption { type = types.str; default = group; description = "Dashboard group (vm-102 lays them out)."; };
      name = mkOption { type = types.str; default = lib.toUpper (lib.substring 0 1 name) + lib.substring 1 (-1) name; description = "Card title."; };
      icon = mkOption { type = types.str; default = icon; description = "Card icon (a homepage icon name)."; };
      description = mkOption { type = types.str; default = description; description = "Card subtitle."; };
      widget = mkOption { type = types.nullOr widgetType; default = null; description = "The card's live widget."; };
    };
  };

  # one route: <host>.<domain><path> on the zone's ingress, its backend, its protection; `backend` adds the fields
  # of a swarm app's route (the stack service and its container port), empty for an instance's own port
  exposureOptions = { name, zone, features, backend ? { } }: backend // {
    host = mkOption { type = dnsLabel; default = name; description = "<host>.<site.domain>."; };
    path = mkOption { type = urlPrefix; default = "/"; description = "Url prefix the route serves."; };
    zone = mkOption {
      type = types.enum [ "internal" "external" ];
      default = zone;
      description = "internal: vm-100 behind authelia; external: the edge, public.";
    };
    port = mkOption { type = types.port; description = "The backend port: on the instance, or published by every swarm node."; };
    protocol = mkOption {
      type = types.enum [ "http" "tcp" "udp" ];
      default = "http";
      description = "http: through the zone's ingress; tcp, udp: straight to the port, from the lab or the router's forward.";
    };
    publicPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "tcp, udp: the house's public port the router forwards; null: lab-only, guarded like an http port.";
    };
    srv = mkOption {
      type = types.nullOr (types.strMatching "_[a-z0-9-]+\\._(tcp|udp)");
      default = null;
      description = "tcp, udp: the SRV record clients look up (\"_minecraft._tcp\").";
    };
    health = mkOption {
      type = types.nullOr urlPath;
      default = null;
      description = "Path the prober, the status dot and the ingress's health check call past sso, below 500 when up; null: none (an instance service: its path).";
    };
    methods = mkOption { type = types.listOf (types.enum webMethods); default = webMethods; description = "Methods routed; others 404."; };
    sources = mkOption {
      type = types.nullOr (types.listOf types.str);
      default = null;
      description = "Client ranges the route admits (by socket address); null: any.";
    };
    basicAuth = mkOption {
      type = types.nullOr (types.attrsOf types.str);
      default = null;
      description = "user -> sops secret: the ingress asks for these credentials; null: none.";
    };
    loginPaths = mkOption { type = types.listOf urlPath; default = [ ]; description = "Password endpoints the ingress rate limits per client."; };
    ssoPaths = mkOption {
      type = types.listOf (types.strMatching urlSegments);
      default = [ ];
      description = "Url prefixes behind authelia on a route without sso (its metrics, an admin page); the rest stays public.";
    };
    loginRedirect = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          path = mkOption { type = urlPath; description = "The app's own login page."; };
          to = mkOption { type = urlPath; description = "Where the ingress sends it instead (the app's sso start)."; };
        };
      });
      default = null;
      description = "Redirect the app's login page to its sso flow.";
    };
    frames = mkOption { type = types.enum [ "deny" "sameorigin" ]; default = "deny"; description = "Who may frame the pages."; };
    referrer = mkOption { type = types.bool; default = true; description = "false: Referrer-Policy no-referrer (queries in urls)."; };
    bodyLimitBytes = mkOption { type = types.ints.positive; default = bodyLimitDefaultBytes; description = "Request body limit."; };
    limitScale = mkOption { type = types.ints.positive; default = 1; description = "Multiplier on the ingress' per-client and per-route rate and in-flight limits."; };
    headers = mkOption { type = types.attrs; default = { }; description = "Extra traefik headers settings (csp, permissions policy, ...)."; };
    guest = mkOption { type = types.bool; default = false; description = "The example guest account (lldap) may open it."; };
    onion = mkOption {
      type = types.bool;
      default = false;
      description = "Also a tor v3 onion service: the router publishes it, the edge serves its address with the route's chain (external routes only; its key is the router's secret <name>-onion-key, its address src/generated/onions.json).";
    };
    busyPath = mkOption {
      type = types.nullOr urlPath;
      default = null;
      description = "With idle: a path answering 2xx while the backend works, so idle never stops it mid-job.";
    };
    on = mkOption { type = featuresType features; default = [ ]; description = "The features opted into (modules/profiles.nix); none: a plain route to the port."; };
  };

  # the swarm app route's backend; the defaults are the builder's stack of one: service web from the root Dockerfile
  swarmBackend = {
    service = mkOption { type = serviceName; default = "web"; description = "The stack service that answers."; };
    targetPort = mkOption { type = types.port; default = targetPortDefault; description = "The port the service listens on in its container."; };
  };

  # when a deployment stops on its own (an instance's vm, an app's stack) and when it is woken
  idleType = types.submodule {
    options = {
      stopAfter = mkOption {
        type = types.nullOr (types.strMatching "[1-9][0-9]*[smhd]");
        default = null;
        description = "Stop after this long without traffic (\"30m\"); the ingress wakes it on the next request. null: never.";
      };
      wakeAt = mkOption { type = types.nullOr types.str; default = null; description = "A systemd calendar time it is woken at for its own jobs."; };
    };
  };

  # the requests below a url prefix, one regex for traefik's PathRegexp and authelia's `resources` alike: any case and
  # any run of slashes, which many backends fold onto one handler
  prefixPattern = path: "(?i)^" + lib.concatMapStringsSep "/+" lib.escapeRegex (lib.splitString "/" path);

  # each of `features` as a bool, true where `on` names it: what consumers read
  enabledOf = features: on: lib.genAttrs features (feature: lib.elem feature on);

  # a route's features that need one it lacks, or that another makes moot (header): one line each
  featureProblemsOf = where: r: let has = feature: lib.elem feature r.on; in
    lib.optional (r.zone == "external" && has "sso") "${where}: sso on the external zone, which reaches no authelia: take anubis"
    ++ lib.optional (has "sso" && has "anubis") "${where}: anubis behind sso adds nothing, sso stops bots before the app: drop one"
    ++ map (feature: "${where}: ${feature} acts through crowdsec's gate, which the route lacks: add crowdsec")
      (lib.optionals (!(has "crowdsec")) (lib.filter has crowdsecFeatures))
    ++ lib.optional (r.zone == "external" && has "internet")
      "${where}: internet relays an internal route through the edge; an external route is public already: drop it"
    ++ lib.optional (!(publicOf r) && has "cloudflare")
      "${where}: cloudflare proxies the route's public name, which an internal route has with internet alone"
    ++ lib.optional (has "houseUnlimited" && r.sources != null)
      "${where}: houseUnlimited admits the house past the limits, sources admit named clients alone: drop one";

  # the route has a name on the internet: an external one always, an internal one relayed by the edge
  # (a hand-written traefik router names no zone: its `on` says)
  publicOf = r: (r.zone or null) == "external" || lib.elem "internet" r.on;
}
