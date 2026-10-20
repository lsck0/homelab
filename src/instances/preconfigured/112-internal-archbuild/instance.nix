# arch package builds for the lsck0 pacman repo on the nas, wakes nightly
{
  id,
  net,
  profiles,
  ...
}:
{
  vm = {
    bootPhase = "dev";
    needs = [
      "containers"
      "nfs"
    ];
    # the one ballooned guest, a nightly batch job: a build is sure of the floor only, one compile job plus the guest's
    # services (main.nix buildJobs), and borrows up to the ceiling what the fixed guests leave
    memoryMiB = 6144;
    balloonMiB = 2816;
    cores = 8;
    # nightly builds yield the cpu to every interactive guest (proxmox default weight is 100)
    cpuUnits = 25;
    # container image, pacman cache, sources, cargo and go caches, the iso's 10 GB work dir (24.9 GB free at the low of
    # the 10 nights to 2026-10-19)
    diskGiB = 100;
    # a night of builds leaves every interactive guest its share of the cpu and the shared nvme
    cpuLimitCores = 6;
    diskLimits = {
      writeMBps = 300;
      writeIops = 3000;
    };
  };

  idle = {
    stopAfter = "30m";
    # after the nas' 02:00 snapshot and its 04:00 off-site upload have the disk and the uplink
    wakeAt = "05:30";
  };

  services = {
    archbuild = {
      port = 80;
      busyPath = "/busy";
      homepage = {
        group = "Dev";
        icon = "arch-linux";
        name = "Arch Build";
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  alerts =
    let
      # its textfile gauges exist only while it is awake: the last value of the day, with slack for a late build
      lookback = "26h";
    in
    {
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
    archrepo-push-key = "manual"; # ssh key vm-112 pushes the mirror with
    archrepo-signing-key = "manual"; # the pacman repo's gpg key
  };

  shares = {
    "archrepo" = { };
  };
}
