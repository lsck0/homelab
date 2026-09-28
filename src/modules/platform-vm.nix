# qemu guest: disk, bootloader, agent
{ modulesPath, ... }: {
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.growPartition = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  services.qemuGuest.enable = true;
  # lower idle power, same throughput
  powerManagement.cpuFreqGovernor = "powersave";
}
