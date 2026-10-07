# the properties of one deployed service, shared by an instance's services (instance.nix `services`) and a swarm
# app's routes (app.nix `routes`): where it is exposed, how the ingress protects it, what telemetry it gets
#
# Every feature is on unless the service says why not: `off.<feature> = "<why>";`, the reason being the value, so an
# opt-out without one cannot be written. The ingresses (modules/traefik), authelia, lldap, the homepage, the
# prober and the router derive everything from these records; none keeps a per-service list.
#
#   services.git = {
#     port = 80;
#     off = { sso = "logs in itself through authelia oidc"; waf = "git clients push packs the rules misread"; };
#   };
#
# Composition: sso and anubis both stop bots before the app; where sso is on, anubis adds nothing and stays off.
# A route of the external zone is public by definition: sso cannot run there (the dmz reaches no authelia), so an
# external route opts out of sso explicitly.
{ lib }:
let
  inherit (lib) mkOption types;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # what the ingress does for a route
  protectionFeatures = [
    "sso" "anubis" "waf" "crowdsec" "rateLimit" "inflightLimit" "bodyLimit" "botDefense" "secureHeaders" "accessLog"
    # the dns record goes through cloudflare's proxy and the origin refuses anyone else
    "cloudflare"
    # an internal route is relayed by the edge, so it is reachable from the internet behind authelia
    "internet"
    # the backend port answers its zone's ingress and the instance's grants only (modules/network.nix)
    "guard"
    "probe"
    "homepage"
  ];
  # frontend: the browser's otlp beacons at <host>/otlp, relayed by the ingress to the collector (modules/traefik)
  telemetryFeatures = [ "metrics" "logs" "traces" "profiles" "dashboard" "alerts" "frontend" ];
  # what a browser app speaks; anything else matches no router and gets a 404
  webMethods = [ "GET" "HEAD" "POST" "PUT" "PATCH" "DELETE" "OPTIONS" ];
  # webapp-template's request body cap: forms and api calls; an upload route raises it or opts out
  bodyLimitDefaultBytes = 1024 * 1024;
  # where a web server in a container listens unless its app says otherwise (the lab's own examples do)
  targetPortDefault = 8000;

  dnsLabel = types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
  urlPath = types.strMatching "/.*";
  # a reason: any text with a word in it
  why = types.strMatching ".*[a-z].*";
  # a url prefix: / or /segment[/segment...] without a trailing slash
  urlPrefix = types.strMatching "/|(/[A-Za-z0-9._~-]+)+";
  serviceName = types.strMatching "[A-Za-z0-9][A-Za-z0-9_.-]*";

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  # feature -> why it is off; a feature without an entry is on
  offType = features: types.submodule {
    options = lib.genAttrs features (feature: mkOption {
      type = types.nullOr why;
      default = null;
      description = "Why ${feature} is off for this service; null: on.";
    });
  };

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
      settings = mkOption { type = types.attrs; default = { }; description = "Any other widget field, verbatim."; };
    };
  };
in rec {
  inherit protectionFeatures telemetryFeatures webMethods bodyLimitDefaultBytes offType urlPath why serviceName;

  # the dashboard card; a deployment's defaults name its kind (an instance service, an app)
  cardType = { name, group, icon, description }: types.submodule {
    options = {
      group = mkOption { type = types.str; default = group; description = "Dashboard group (vm-103 lays them out)."; };
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
      description = "Path that answers 2xx without a login: the prober, the status dot, the ingress's health check; null: none (instances: /).";
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
    headers = mkOption { type = types.attrs; default = { }; description = "Extra traefik headers settings (csp, permissions policy, ...)."; };
    guest = mkOption { type = types.bool; default = false; description = "The example guest account (lldap) may open it."; };
    busyPath = mkOption {
      type = types.nullOr urlPath;
      default = null;
      description = "With idle: a path answering 2xx while the backend works, so idle never stops it mid-job.";
    };
    off = mkOption { type = offType features; default = { }; description = "Feature -> why it is off."; };
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

  # every feature of a service record as a bool: what consumers read
  enabledOf = off: lib.mapAttrs (_: why: why == null) off;
}
