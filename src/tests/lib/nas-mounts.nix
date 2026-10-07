# a lab node's real nas mounts in a test vm: the vm replaces fileSystems with virtualisation.fileSystems, so the
# mounts modules/nas.nix renders from homelab.nasMounts would never happen. Needs a test nas at the real address
# 10.100.0.109 (lib/lab.nix `nas`); lab.guest imports this for `nas = true`.
{ config, ... }: {
  virtualisation.fileSystems = config.homelab.nasFileSystems;
}
