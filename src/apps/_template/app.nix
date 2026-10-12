# what the app is, in one line
#
# Copy this folder to src/apps/<name>/: the app builds from its repo's Dockerfile (or compose file) and runs on the
# apps swarm, reachable at <name>.<domain> behind the edge and authelia, every protection and telemetry feature on.
# Every field and its default: modules/apps-catalog and modules/service.nix.
#
# The app owns its features and its own authentication and authorization. The platform owns tls, bot defence, rate
# limits, telemetry plumbing, backups and scale to zero. The app declares only what the platform cannot know:
#   routes.<name>        host, path, the stack service and port answering it, `health` (a path below 500 when up)
#   metrics.<name>       a prometheus endpoint, scraped and never routed
#   stateful, volumes    the services with data and whether each volume is archived; `dumps` for a database
#   off.scaleToZero      only for an app that must stay up, with why (a job of its own, clients holding a
#                        connection); every other app sleeps after `idle.stopAfter` (15m) without requests and its
#                        first request wakes it
# A public route's requests, its browser telemetry (<host>/otlp) included, pass Cloudflare's proxy, which decrypts them;
# a route carrying credentials (a ci token) sets `off.cloudflare` and is served from the house's address directly.
# Not public: a `metrics` path that a public route serves too is denied at the edge for everyone (catalog
# metricsBlocks), the collector scrapes its own published port. A public route of the internal zone may instead keep
# prefixes behind authelia, `ssoPaths = [ "/admin" ];`, open to admins and the route's group; the edge has no authelia,
# so an external route can only block a path, never gate it.
{
  enable = true;
  repo = "lsck0/demo";
  branch = "master";
}
