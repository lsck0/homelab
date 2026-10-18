# what the app is, in one line
#
# copy to src/instances/custom/<name>/; fields and defaults: modules/apps-catalog, README.md "Adding an app"
# a route carrying credentials (a ci token) leaves cloudflare out: its proxy decrypts every request
{ ... }: {
  enable = true;
  repo = "lsck0/demo";
  branch = "master";
  # defended, probed, observed, on the dashboard, asleep when idle
  # routes.demo.on = profiles.hardenedExternal ++ [ "probe" ];
  # on = profiles.observed ++ profiles.traced ++ [ "frontend" "homepage" "scaleToZero" ];
  # protection per path: /api rate limited, the rest of the host plain
  # routes.demo-api = { host = "demo"; path = "/api"; port = 20131; on = [ "rateLimit" ]; };
}
