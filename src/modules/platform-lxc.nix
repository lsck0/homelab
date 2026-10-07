# proxmox container: host kernel, no bootloader or disk setup
{ config, inventory, modulesPath, ... }:
let
  # the template build has no instance
  instance = if config.homelab.vmid == null then { } else inventory.${config.homelab.vmid} or { };
in {
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    # proxmox writes eth0 for networkd, so a fresh container is reachable before its first deploy
    manageNetwork = false;
    manageHostName = true;
    # instance.nix vm.privileged decides, nfs mounts need it
    privileged = instance.privileged or false;
  };
}
