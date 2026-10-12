# lab-gate (lib/gate, its header says what it does): the package, its loopback ports, and the forwardauth
# middleware a route's features ask for; modules/traefik wires them into every gated router's chain
#
#   gate = import ./lib/gate.nix { inherit pkgs lib; };
#   gate.middlewareName { captcha = true; limit = true; tarpit = true; scale = 1; }       # "gate"
#   gate.middlewareName { captcha = false; limit = true; tarpit = true; scale = 20; }     # "gate-nocaptcha-x20"
{ pkgs, lib }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  loopback = "127.0.0.1";
  port = 27100;
  tarpitPort = 27101;
  authPath = "/auth";
  metricsPath = "/metrics";
  # the captcha form's target on every host; dotted, so no app's own path is shadowed
  answerPath = "/.lab-gate/answer";
  # the go module's binary
  binary = "gate";
  # what forwardauth passes the gate: the client client-ip named and the cookies (its own, authelia's); nothing else
  # of the request leaves traefik but forwardauth's own X-Forwarded-Host and -Uri (an onion route's address, the path)
  authRequestHeaders = [ "X-Real-Ip" "Cookie" ];
  flagNames = [ "captcha" "limit" "tarpit" ];
  # a captcha page is under 32 KiB (a png of flat shapes); traefik reads no gate answer past this
  pageBytesMax = 256 * 1024;

  # -----------------------------------------------------------------------------
  # FUNCTIONS
  # -----------------------------------------------------------------------------

  bit = on: if on then "1" else "0";
  middlewareName = flags: "gate"
    + lib.concatMapStrings (name: lib.optionalString (!flags.${name}) "-no${name}") flagNames
    + lib.optionalString (flags.scale != 1) "-x${toString flags.scale}";
in {
  inherit loopback port tarpitPort answerPath metricsPath middlewareName;

  # go's standard library only; buildGoModule runs its tests (gate_test.go) before anything ships
  package = pkgs.buildGoModule {
    pname = "lab-gate";
    version = "1.0.0";
    src = lib.fileset.toSource { root = ./gate; fileset = ./gate; };
    vendorHash = null;
    env.CGO_ENABLED = "0";
    meta.mainProgram = binary;
  };

  # flags: { captcha; limit; tarpit; scale; } -> its traefik middleware
  middleware = flags: {
    forwardAuth = {
      address = "http://${loopback}:${toString port}${authPath}?"
        + lib.concatMapStrings (name: "${name}=${bit flags.${name}}&") flagNames + "scale=${toString flags.scale}";
      inherit authRequestHeaders;
      maxResponseBodySize = pageBytesMax;
    };
  };
}
