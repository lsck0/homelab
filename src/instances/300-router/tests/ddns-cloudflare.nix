# lib/ddns-cloudflare.sh against a fake ipify and cloudflare api, faults injected (tests/ddns_cloudflare_test.py)
{ pkgs, ... }:
pkgs.runCommand "ddns-cloudflare" {
  nativeBuildInputs = [ pkgs.python3 pkgs.bash pkgs.curl pkgs.jq pkgs.findutils pkgs.coreutils ];
  DDNS_SCRIPT = ../lib/ddns-cloudflare.sh;
} ''
  python3 ${./ddns_cloudflare_test.py}
  touch $out
''
