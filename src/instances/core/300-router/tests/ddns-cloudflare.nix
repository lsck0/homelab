# lib/ddns-cloudflare.nu against a fake cloudflare api, faults injected (tests/ddns_cloudflare_test.py)
{ pkgs, ... }:
pkgs.runCommand "ddns-cloudflare" {
  nativeBuildInputs = [ pkgs.python3 pkgs.curl pkgs.coreutils ];
  DDNS_SCRIPT = pkgs.writers.writeNu "ddns-cloudflare" ../lib/ddns-cloudflare.nu;
} ''
  python3 ${./ddns_cloudflare_test.py}
  touch $out
''
