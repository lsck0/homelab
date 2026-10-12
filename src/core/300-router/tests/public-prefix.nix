# lib/public-prefix.sh against a faked fritzbox (public_prefix_test.sh): the delegated ipv6 prefix published as a
# hosts line, any answer that is no prefix of the expected length refused with the last one kept
{ pkgs, ... }:
pkgs.runCommand "public-prefix" { nativeBuildInputs = with pkgs; [ bash coreutils gnused gnugrep ]; } ''
  bash ${./public_prefix_test.sh} ${../lib/public-prefix.sh}
  touch $out
''
