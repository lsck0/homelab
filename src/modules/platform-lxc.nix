# proxmox container: host kernel, no bootloader or disk setup
{ config, inventory, modulesPath, ... }:
let
  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  # the template build has no instance
  instance = if match == null then { } else inventory.${builtins.head match} or { };
in {
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    # proxmox writes eth0 for networkd, so a fresh container is reachable before its first deploy
    manageNetwork = false;
    manageHostName = true;
    # instances.tf decides, nfs mounts need it
    privileged = instance.privileged or false;
  };
}
