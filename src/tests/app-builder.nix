# the app builder's stack handling: stack file conventions, build hints, env inlining (tests/app_builder_test.py)
{ pkgs, ... }:
pkgs.runCommand "app-builder" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; } ''
  python3 ${./app_builder_test.py} ${../scripts/app-builder.py}
  touch $out
''
