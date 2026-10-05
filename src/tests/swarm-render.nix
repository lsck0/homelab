# the apps swarm's policy: what scripts/swarm-render.py refuses and what it adds (tests/swarm_render_test.py)
{ pkgs, ... }:
pkgs.runCommand "swarm-render" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; } ''
  python3 ${./swarm_render_test.py} ${../scripts/swarm-render.py}
  touch $out
''
