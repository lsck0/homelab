# the deploy controller: the apps swarm's manager (raft, scheduling, deploys, modules/swarm) and the app builder
# (lib/app-builder.nix, rootless as appbuild, never against the swarm's root docker socket)
{ ... }: {
  imports = [
    ../../modules/rootless-docker.nix
    ./lib/app-builder.nix
  ];

  # a build could otherwise run fixed-output derivations, which run as nixbld with the network
  nix.settings.allowed-users = [ "root" ];
}
