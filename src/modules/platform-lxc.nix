# unprivileged proxmox container: host kernel, no bootloader or disk setup
{ modulesPath, ... }: {
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    # proxmox writes eth0 for networkd, so a fresh container is reachable before its first deploy
    manageNetwork = false;
    manageHostName = true;
    privileged = false;
  };
}
