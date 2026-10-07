# the proxmox node every guest shares: the memory the host budget (tests/policy/guests.nix) holds the guests to
{
  # MemTotal of the node (32 GiB less the firmware's share)
  memoryMiB = 32022;
  # zfs_arc_max as measured; the guest disks are lvm-thin, and with no zfs pool the arc holds nothing (0), which
  # `zpool list` on the node shows
  arcMaxMiB = 3202;
  # the node's own kernel, pve daemons and the page cache of the guest disks
  reserveMiB = 2048;
}
