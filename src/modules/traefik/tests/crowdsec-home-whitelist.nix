# lib/crowdsec-home-whitelist.sh against a faked resolver and podman (crowdsec_home_whitelist_test.sh): the house's
# v4 address and v6 prefix whitelisted and their bans lifted as the router serves them, an unknown prefix kept
{ pkgs, ... }:
pkgs.runCommand "crowdsec-home-whitelist" {
  nativeBuildInputs = with pkgs; [ bash coreutils diffutils gnused gnugrep yq-go ];
} ''
  bash ${./crowdsec_home_whitelist_test.sh} ${../lib/crowdsec-home-whitelist.sh}
  touch $out
''
