# arch package builds for the lsck0 pacman repo on the nas, wakes nightly
{ ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # the host idles near its 80% balloon line, so a build gets the floor: 3072 left cargo 58 MiB
    memoryMiB = 6144;
    balloonMiB = 5120;
    cores = 8;
    # nightly builds yield the cpu to every interactive guest (proxmox default weight is 100)
    cpuUnits = 25;
    # container image, pacman cache, sources, cargo and go caches
    diskGiB = 100;
  };

  idle = { stopAfter = "30m"; wakeAt = "03:00"; };

  services = {
    archbuild = {
      port = 80;
      busyPath = "/busy";
      homepage = { group = "Dev"; icon = "arch-linux"; name = "Arch Build"; };
    };
  };

  secrets = {
    archrepo-push-key = "manual"; # ssh key vm-119 pushes the mirror with
    archrepo-signing-key = "manual"; # the pacman repo's gpg key
  };
}
