# the apps swarm's manager: raft, scheduling and deploys (modules/swarm.nix); its workers are the apps zone's vms
{ ... }: {
  networking.hostName = "vm-140";
}
