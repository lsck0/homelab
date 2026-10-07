# the telemetry relay's tenant map against a fake docker api (relay_tenants_test.py), linted at the lab's width
{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ ps.flake8 ]);
  # the lab's line width
  lineMax = 150;
in
pkgs.runCommand "relay-tenants" { nativeBuildInputs = [ python ]; } ''
  python3 -m flake8 --max-line-length ${toString lineMax} ${./relay_tenants_test.py} ${../lib/relay-tenants.py}
  python3 ${./relay_tenants_test.py} ${../lib/relay-tenants.py}
  touch $out
''
