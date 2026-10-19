# a heavy nas job (the off-site runs, the syncthing snapshot, the kopia verify, the arch mirror) holds `lock` while it
# runs and is capped at `memoryMaxMiB`: one at a time fits the guest's floor, and proton allows one cli session
{ lab }:
let
  nasVm = lab.instances.${lab.roles.nas}.config.vm;
  # the floor the host cannot balloon away
  guaranteedMiB = if nasVm.balloonMiB == 0 then nasVm.memoryMiB else nasVm.balloonMiB;
  # nfsd, smbd, syncthing, filebrowser, nginx and the kernel: 532 MiB used with no job running (2026-10-18)
  servingReserveMiB = 640;
in
{
  inherit guaranteedMiB servingReserveMiB;
  lock = "/run/nas-job.lock";
  memoryMaxMiB = guaranteedMiB - servingReserveMiB;
}
