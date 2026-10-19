# lab-wide: the Proxmox host's converge (scripts/pve-install.nu)
# pve-install.nu's own decisions with pveum, qm, pct, apt-get and wget stubbed (pve_install_test.nu): the lldap realm
# fails closed and binds over ldaps, the node address and api certificate converge without touching a cluster or an
# address the host lacks, the recovery settings reboot a hung host and a softdog fed instead of the hardware watchdog
# is reported, root's ssh takes keys alone, the lab's subnets route through the router, the firewall runs on nftables,
# an upgrade keeps the host's config files and names the kernel a reboot starts, the teardown leaves no firewall rule
# behind, and an unavailable mirror or github never stops the converge. No network.
{ pkgs, ... }:
pkgs.runCommand "pve-install"
  {
    nativeBuildInputs = with pkgs; [
      nushell
      coreutils
      gnused
      lvm2
    ];
  }
  ''
    export HOME=$TMPDIR
    nu --no-config-file ${./pve_install_test.nu} ${../scripts/pve-install.nu}
    touch $out
  ''
