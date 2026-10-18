# proxmox container: host kernel, no bootloader or disk setup
{ config, lib, inventory, modulesPath, ... }:
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

  # unprivileged, /run/user/<uid> is no tmpfs of its own: every logout fails the stop ("Failed to remove runtime
  # directory ... Directory not empty", 58 a week on 211) though the next login works; masking it would fail user@<uid>
  systemd.services."user-runtime-dir@".serviceConfig.ExecStop = lib.mkIf (!config.proxmoxLXC.privileged)
    [ "" "-${config.systemd.package}/lib/systemd/systemd-user-runtime-dir stop %i" ];
}
