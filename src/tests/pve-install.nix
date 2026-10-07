# lab-wide: the Proxmox host's converge (scripts/pve-install.sh)
# pve-install.sh's own decisions with pveum, qm, pct, apt-get and wget stubbed (pve_install_test.sh): the lldap realm
# fails closed and binds over ldaps, and an unavailable mirror or github never stops the converge. No network.
{ pkgs, ... }:
pkgs.runCommand "pve-install" {
  nativeBuildInputs = with pkgs; [ bash jq coreutils gnugrep diffutils ];
} ''
  bash ${./pve_install_test.sh} ${../scripts/pve-install.sh}
  touch $out
''
