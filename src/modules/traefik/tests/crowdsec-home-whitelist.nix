# lib/crowdsec-home-whitelist.nu against a faked resolver and podman (crowdsec_home_whitelist_test.nu)
{ pkgs, ... }:
pkgs.runCommand "crowdsec-home-whitelist" { nativeBuildInputs = [ pkgs.nushell pkgs.coreutils ]; } ''
  nu --no-config-file ${./crowdsec_home_whitelist_test.nu} ${../lib/crowdsec-home-whitelist.nu}
  touch $out
''
