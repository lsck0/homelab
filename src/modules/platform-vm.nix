# qemu guest: disk, bootloader, agent
{
  config,
  lib,
  modulesPath,
  ...
}:
let
  dropCachesEveryMin = 30;
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.homelab.dropCaches = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Drop clean page cache every ${toString dropCachesEveryMin} min so free-page reporting hands it back to the host.";
  };

  config = {
    boot.loader.grub.enable = true;
    boot.loader.grub.device = "/dev/sda";
    boot.growPartition = true;

    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };

    services.qemuGuest.enable = true;
    # hands freed blocks back to the thin pools (disks are discard=on)
    services.fstrim.enable = true;
    # lower idle power, same throughput
    powerManagement.cpuFreqGovernor = "powersave";

    # guest cache is host ram: reclaim dentries/inodes (nfs) harder than the default 100
    boot.kernel.sysctl."vm.vfs_cache_pressure" = 300;
    systemd.services.drop-page-cache = lib.mkIf config.homelab.dropCaches {
      description = "Return clean page cache to the host";
      startAt = "*:0/${toString dropCachesEveryMin}";
      serviceConfig.Type = "oneshot";
      script = "sync; echo 1 > /proc/sys/vm/drop_caches";
    };
    # a fixed offset per guest within the period: every guest syncing and refaulting in the same second loads the
    # host's disks at once
    systemd.timers.drop-page-cache.timerConfig = lib.mkIf config.homelab.dropCaches {
      RandomizedDelaySec = "${toString (dropCachesEveryMin - 1)}min";
      FixedRandomDelay = true;
    };
  };
}
