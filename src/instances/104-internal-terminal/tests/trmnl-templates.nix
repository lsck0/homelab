# the TRMNL templates against what the feeds publish, in the engine TRMNL renders with (trmnl_templates_test.rb):
# every output escaped, every key a template reads present in its payload, hostile strings escaped
{ pkgs, lib, ... }:
let
  # the payloads come from the real builders, run by feeds.nix
  feeds = import ./feeds.nix { inherit pkgs lib; };
  ruby = pkgs.ruby.withPackages (ps: [ ps.liquid ps.minitest ]);
in
pkgs.runCommand "trmnl-templates" { nativeBuildInputs = [ ruby ]; } ''
  ruby ${./trmnl_templates_test.rb} ${../lib/trmnl} ${feeds}/payloads --seed 1
  touch $out
''
