# lib/public-prefix.nu against a faked fritzbox (public_prefix_test.nu): the delegated ipv6 prefix published as a
# hosts line, any answer that is no prefix of the expected length refused with the last one kept
{ pkgs, ... }:
let
  # unwrapped: the test's fake curl must come first on PATH
  script = pkgs.writers.writeNu "public-prefix" ../lib/public-prefix.nu;
in
pkgs.runCommand "public-prefix" { nativeBuildInputs = with pkgs; [ nushell bash coreutils ]; } ''
  nu --no-config-file ${./public_prefix_test.nu} ${script}
  touch $out
''
