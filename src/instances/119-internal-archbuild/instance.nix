# arch package builds for the lsck0 pacman repo on the nas, wakes nightly
{ id, net, ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    # the host idles near its 80% balloon line, so a build is sure of the floor only: one compile job plus the guest's
    # own services (main.nix buildJobs), the ceiling is headroom
    memoryMiB = 6144;
    balloonMiB = 2816;
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

  alerts = let
    # its textfile gauges exist only while it is awake: the last value of the day, with slack for a late build
    lookback = "26h";
  in {
    archrepo_missing = {
      title = "Arch mirror lacks listed packages";
      category = "builds";
      expr = "last_over_time(homelab_archrepo_missing_packages[${lookback}])";
      threshold = 0;
      for = "0m";
      summary = "lsck0 snapshot: {{ $values.A }} listed packages missing";
      description = "Listed in arch-dotfiles but not served by mirror.lsck0.dev; a fresh install misses them. `curl -s http://${net.ipOf id}/status.txt` lists them, logs/<base>.log says why.";
    };
    archrepo_held_back = {
      title = "Arch mirror snapshot held back";
      category = "builds";
      expr = "last_over_time(homelab_archrepo_held_back[${lookback}])";
      threshold = 0;
      for = "0m";
      summary = "lsck0 snapshot held back";
      description = "The nightly build did not publish; status.txt `published:` says why. Clients keep the previous snapshot.";
    };
  };

  secrets = {
    archrepo-push-key = "manual"; # ssh key vm-119 pushes the mirror with
    archrepo-signing-key = "manual"; # the pacman repo's gpg key
  };

  shares = {
    "bulk/archrepo" = { };
  };
}
