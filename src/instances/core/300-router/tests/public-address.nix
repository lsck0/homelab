# lib/public-address.nu against a faked fritzbox (public_address_test.nu): the public ipv4 address and the delegated
# ipv6 prefix published as hosts lines, any answer that is no such address refused with the last one kept
{ pkgs, ... }:
let
  # unwrapped: the test's fake curl must come first on PATH
  script = pkgs.writers.writeNu "public-address" ../lib/public-address.nu;
in
pkgs.runCommand "public-address"
  {
    nativeBuildInputs = with pkgs; [
      nushell
      bash
      coreutils
    ];
  }
  ''
    nu --no-config-file ${./public_address_test.nu} ${script}
    touch $out
  ''
