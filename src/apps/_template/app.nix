# what the app is, in one line
#
# Copy this folder to src/apps/<name>/: the app builds from its repo's Dockerfile (or compose file) and runs on the
# apps swarm, reachable at <name>.<domain> behind the edge and authelia, every protection and telemetry feature on.
# Every field and its default: modules/apps-catalog and modules/service.nix.
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
