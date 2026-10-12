# named feature lists to opt into: a service's `on` (modules/service.nix), an app's (modules/apps-catalog) and a
# guest's (modules/instance-schema.nix) concatenate them, plus single names, and lib.subtractLists drops one
#
#   services.git.on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
#   on = profiles.vpnEgress;                                            (instance.nix: the guest's own)
#
# instance.nix and app.nix get this file as the argument `profiles`.
let
  # a route's defences whichever zone serves it: the ingress's chain (modules/traefik), the guard on the backend
  # port, and its public name behind cloudflare's proxy
  defences = [
    "waf" "crowdsec" "rateLimit" "inflightLimit" "bodyLimit" "botDefense" "secureHeaders" "accessLog" "captcha"
    "anonymousLimit" "tarpit" "guard" "cloudflare"
  ];
in {
  # behind authelia, which stops bots before the app; reachable from the internet through the edge's relay
  hardenedInternal = [ "sso" "internet" ] ++ defences;
  # public: the dmz reaches no authelia, anubis stops the bots
  hardenedExternal = [ "anubis" ] ++ defences;
  # a card on the dashboard, its status dot and vm-103 the prober's check
  listed = [ "homepage" "probe" ];
  # scraped, its logs kept, a board of its own and its alert rules
  observed = [ "metrics" "logs" "dashboard" "alerts" ];
  # an app's traces and profiles sent to its tenant on vm-103
  traced = [ "traces" "profiles" ];

  # the guest's internet traffic through the router's vpn exit, or its tor (killswitch either way)
  vpnEgress = [ "vpnEgress" ];
  torEgress = [ "torEgress" ];
}
