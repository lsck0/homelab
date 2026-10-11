# the proxmox node every guest shares: the memory the host budget (tests/policy/guests.nix) holds the guests to
{
  # MemTotal of the node (32 GiB less the firmware's share)
  memoryMiB = 32022;
  # the zfs arc is capped at 3202 MiB, but the node has no zfs pool (its storage is lvm-thin), so the arc holds nothing
  arcMaxMiB = 0;
  # the node's own kernel, pve daemons and the page cache of the guest disks
  reserveMiB = 2048;
}
