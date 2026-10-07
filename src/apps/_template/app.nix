# what the app is, in one line
#
# Copy this folder to src/apps/<name>/: the app builds from its repo's Dockerfile (or compose file) and runs on the
# apps swarm, reachable at <name>.<domain> behind the edge and authelia, every protection and telemetry feature on.
# Every field and its default: modules/apps-catalog and modules/service.nix.
{
  enable = true;
  repo = "lsck0/demo";
  branch = "master";
}
