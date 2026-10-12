# what the app is, in one line
#
# Copy this folder to src/instances/custom/<name>/: the app builds from its repo's Dockerfile (or compose file) and runs on the
# apps swarm, a plain route at <name>.<domain> through the edge to its port, nothing more. Every field and its default:
# modules/apps-catalog and modules/service.nix; app.nix is a function of { lib, profiles } (modules/profiles.nix).
#
# The app owns its features and its own authentication and authorization. The platform offers tls, bot defence, rate
# limits, telemetry plumbing, backups and scale to zero, each by name in an `on` list. The app declares only what the
# platform cannot know:
#   routes.<name>        host, path, the stack service and port answering it, `health` (a path below 500 when up),
#                        `on` its protection
#   metrics.<name>       a prometheus endpoint, scraped and never routed
#   stateful, volumes    the services with data and whether each volume is archived; `dumps` for a database
#   on                   its telemetry, its card, and scaleToZero: it sleeps after `idle.stopAfter` (15m) without
#                        requests and its first request wakes it; an app with a job of its own, or clients holding a
#                        connection, stays up without it
# A route with cloudflare passes Cloudflare's proxy, which decrypts its requests, its browser telemetry (<host>/otlp)
# included; a route carrying credentials (a ci token) leaves it out and is served from the house's address directly.
# Not public: a `metrics` path that a public route serves too is denied at the edge for everyone (catalog
# metricsBlocks), the collector scrapes its own published port. A public route of the internal zone may instead keep
# prefixes behind authelia, `ssoPaths = [ "/admin" ];`, open to admins and the route's group; the edge has no authelia,
# so an external route can only block a path, never gate it.
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
