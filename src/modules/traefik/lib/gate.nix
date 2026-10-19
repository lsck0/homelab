# lab-gate (lib/gate, its header says what it does): the package, its loopback ports, and the forwardauth
# middleware a route's features ask for; modules/traefik wires them into every gated router's chain
#
#   gate = import ./lib/gate.nix { inherit pkgs lib; };
#   gate.middlewareName { captcha = true; limit = true; tarpit = true; crawlers = true; scale = 1; }    # "gate"
#   gate.middlewareName { captcha = false; limit = true; tarpit = true; crawlers = false; scale = 20; } # "gate-nocaptcha-nocrawlers-x20"
#
# The deception (lib/gate deception.go): the gate answers forwardauth with an unassigned 4xx status for a client
# crowdsec deceives or a forged search crawler, which backends do not use; the errors middlewares in front of it turn
# that into a fetch of the gate's deception listener and a 200. They catch the status from anything behind them, the
# backend included: the deception checks the reason again and answers a visitor it does not deceive with a logged bad
# gateway without the forged crawler's outcome header, so a backend answering 452 or 453 itself shows an error page, not
# its own answer, and trips no signal (lib/ladder.nix).
{ pkgs, lib }:
let

  loopback = "127.0.0.1";
  port = 27100;
  tarpitPort = 27101;
  deceptionPort = 27102;
  statusDeceive = 452;
  statusForgedCrawler = 453;
  deceptionStatus = 200;
  authPath = "/auth";
  stripPath = "/strip";
  metricsPath = "/metrics";
  # the captcha form's target on every host; dotted, so no app's own path is shadowed
  answerPath = "/.lab-gate/answer";
  binary = "gate";
  # what forwardauth passes the gate: the client client-ip named, the cookies (its own, authelia's) and the user agent
  # a search crawler names itself by; nothing else of the request leaves traefik but forwardauth's own
  # X-Forwarded-Host and -Uri (an onion route's address, the path)
  authRequestHeaders = [
    "X-Real-Ip"
    "Cookie"
    "User-Agent"
  ];
  flagNames = [
    "captcha"
    "limit"
    "tarpit"
    "crawlers"
  ];
  deceptionUrl = "http://${loopback}:${toString deceptionPort}";
  # the gate's deception listener's paths (deception.go)
  honeypotPrefix = "/honeypot";
  errorsOf = status: service: path: {
    status = [ (toString status) ];
    inherit service;
    query = "${path}?url={url}";
    statusRewrites.${toString status} = deceptionStatus;
  };
  # what the strip reads and rewrites of a request
  stripHeaders = [ "Cookie" ];
  # a captcha page is under 32 KiB (a png of flat shapes); traefik reads no gate answer past this
  pageBytesMax = 256 * 1024;

  bit = on: if on then "1" else "0";
  middlewareName =
    flags:
    "gate"
    + lib.concatMapStrings (name: lib.optionalString (!flags.${name}) "-no${name}") flagNames
    + lib.optionalString (flags.scale != 1) "-x${toString flags.scale}";
in
{
  inherit
    loopback
    port
    tarpitPort
    deceptionPort
    statusDeceive
    statusForgedCrawler
    deceptionUrl
    answerPath
    metricsPath
    middlewareName
    ;

  # go's standard library only; buildGoModule runs its tests (gate_test.go) before anything ships
  package = pkgs.buildGoModule {
    pname = "lab-gate";
    version = "1.0.0";
    src = lib.fileset.toSource {
      root = ./gate;
      fileset = ./gate;
    };
    vendorHash = null;
    env.CGO_ENABLED = "0";
    meta.mainProgram = binary;
  };

  stripMiddlewareName = "strip-session-cookie";
  # traefik replaces the request's cookies with the gate's answer: the client's without the sso portal's
  stripMiddleware.forwardAuth = {
    address = "http://${loopback}:${toString port}${stripPath}";
    authRequestHeaders = stripHeaders;
    authResponseHeaders = stripHeaders;
  };

  # the errors middlewares every gated router's chain names right before its gate, part of it (named gate-*)
  deceptionMiddlewareNames = [
    "gate-deception-crawler"
    "gate-deception"
  ];
  deceptionMiddlewares = {
    gate-deception.errors = errorsOf statusDeceive "deception" "/deceive";
    gate-deception-crawler.errors = errorsOf statusForgedCrawler "deception-crawler" "/forged-crawler";
  };
  # the services of the errors middlewares, and the honeypot router's, which asks with the request's path under its own;
  # the access log names the service that answered: crowdsec's forged-crawler signal reads it (lib/ladder.nix)
  deceptionServices =
    lib.genAttrs [ "deception" "deception-crawler" ] (_: {
      loadBalancer.servers = [ { url = deceptionUrl; } ];
    })
    // {
      deception-honeypot.loadBalancer.servers = [
        {
          url = deceptionUrl + honeypotPrefix;
          preservePath = true;
        }
      ];
    };
  forgedCrawlerService = "deception-crawler@file";

  # flags: { captcha; limit; tarpit; crawlers; scale; } -> its traefik middleware
  middleware = flags: {
    forwardAuth = {
      address =
        "http://${loopback}:${toString port}${authPath}?"
        + lib.concatMapStrings (name: "${name}=${bit flags.${name}}&") flagNames
        + "scale=${toString flags.scale}";
      inherit authRequestHeaders;
      maxResponseBodySize = pageBytesMax;
    };
  };
}
