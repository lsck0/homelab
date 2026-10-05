# a node of the apps swarm; modules/swarm.nix makes it one from the inventory, the catalog runs the apps
{ ... }: {
  networking.hostName = "vm-152";
}
