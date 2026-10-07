# the options of modules/platform-vm.nix a lab module sets; a test vm cannot import the platform itself (grub,
# disk layout, cloud-init)
{ lib, ... }: {
  options.homelab.dropCaches = lib.mkOption { type = lib.types.bool; default = true; };
}
