# what the app is, in one line
#
# copy to src/instances/custom/<name>/; fields and defaults: modules/apps-catalog, README.md "Adding an app"
# a route carrying credentials (a ci token) leaves cloudflare out: its proxy decrypts every request
{ profiles, ... }:
{
  enable = true;
  repo = "lsck0/demo";
  branch = "master";
  # observed, and its spans continue the ingress's trace (traceparent)
  on = profiles.observed ++ profiles.traced;
  # on the dashboard, asleep when idle
  # on = profiles.observed ++ profiles.traced ++ [ "frontend" "homepage" "scaleToZero" ];
  # defended and probed
  # routes.demo.on = profiles.hardenedExternal ++ [ "probe" ];
  # protection per path: /api rate limited, the rest of the host plain
  # routes.demo-api = { host = "demo"; path = "/api"; port = 20131; on = [ "rateLimit" ]; };

  # a generated secret and a third party's, which `sops` sets by hand; the app does not deploy while one is empty
  # secrets = { db-password = "guardsData:hex:32"; smtp-password = "manual"; };
  # in one service's environment, or as a file for an image that reads <KEY>_FILE (in no spec or `docker inspect`)
  # env.server.DATABASE_PASSWORD = "{{db-password}}";
  # secretFiles.server.SMTP_PASSWORD = "smtp-password";
  # a nightly consistent dump to the nas, and how swarm-dump-restore reads one back
  # dumps.postgres = { service = "postgres"; command = "pg_dumpall -U admin"; restore = "psql -U admin -d postgres"; };
}
