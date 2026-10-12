# the app builder: its stack handling table by table (tests/app_builder_test.py), and its state machine in a
# deterministic simulation with fault injection over 1000 seeds (tests/app_builder_sim_test.py; rerun one seed with
# `python3 src/instances/140-internal-swarm/tests/app_builder_sim_test.py src/instances/140-internal-swarm/lib/app-builder.py <seed>`)
{ pkgs, ... }:
pkgs.runCommand "app-builder" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) pkgs.git ]; } ''
  python3 ${./app_builder_test.py} ${../lib/app-builder.py}
  python3 ${./app_builder_sim_test.py} ${../lib/app-builder.py}
  touch $out
''
