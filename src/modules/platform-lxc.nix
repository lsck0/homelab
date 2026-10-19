# proxmox container: host kernel, no bootloader or disk setup; never privileged (tests/policy/guests.nix)
{ config, modulesPath, ... }:
{
  imports = [ (modulesPath + "/virtualisation/proxmox-lxc.nix") ];

  proxmoxLXC = {
    # proxmox writes eth0 for networkd, so a fresh container is reachable before its first deploy
    manageNetwork = false;
    manageHostName = true;
  };

  # unprivileged, /run/user/<uid> is no tmpfs of its own: every logout fails the stop ("Failed to remove runtime
  # directory ... Directory not empty", 58 a week on 211) though the next login works; masking it would fail user@<uid>
  systemd.services."user-runtime-dir@".serviceConfig.ExecStop = [
    ""
    "-${config.systemd.package}/lib/systemd/systemd-user-runtime-dir stop %i"
  ];
}
