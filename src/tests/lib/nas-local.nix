# a lab node's nas mounts in a test vm without a nas: each one bind-mounts a directory on the vm's own disk
#
# The mounts keep their mountpoints, read-only flag and systemd options (automount, timeouts), so everything keyed
# on them behaves as in the lab: nas.nix's nas-tmpfiles, the containers that require the automounts, services that
# write below a mountpoint before anything else created it. Only the nfs transport is gone; lab.guest imports
# this unless `nas = true` (lib/nas-mounts.nix, a real test nas).
{ config, lib, ... }:
let
  # where the shares live on the vm disk: /srv/lab-nas/data/<share> for 10.100.0.109:/srv/nas/data/<share>
  localRoot = "/srv/lab-nas";
  localOf = device: localRoot + lib.removePrefix "/srv/nas" (lib.last (lib.splitString ":" device));
  # the systemd and access options carry over; the nfs ones (nfsvers, hard, timeo, retry, ...) mean nothing here
  keep = option: lib.elem option [ "ro" "rw" "_netdev" ] || lib.hasPrefix "x-systemd." option;
in {
  # activation runs before systemd mounts anything; a tmpfiles rule would need an ordering that cycles with
  # local-fs.target for the mounts without automount
  system.activationScripts.labNasLocal = lib.concatMapStrings (m: ''
    install -d -m 0777 ${lib.escapeShellArg (localOf m.device)}
  '') (lib.attrValues config.homelab.nasMounts);

  virtualisation.fileSystems = lib.mapAttrs (_: m: {
    device = localOf m.device;
    fsType = "none";
    options = [ "bind" ] ++ lib.filter keep m.options;
  }) config.homelab.nasMounts;
}
