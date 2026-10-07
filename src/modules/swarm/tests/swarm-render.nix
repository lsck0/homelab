# the apps swarm's policy: what lib/swarm-render.py refuses and adds (tests/swarm_render_test.py, table by table),
# and the laws of both platform parsers over generated input (tests/render_properties_test.py, hypothesis,
# derandomized: the same examples every run)
{ pkgs, ... }:
pkgs.runCommand "swarm-render" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ps.hypothesis ])) ]; } ''
  python3 ${./swarm_render_test.py} ${../lib/swarm-render.py}
  python3 ${./render_properties_test.py} ${../lib/swarm-render.py} ${../../../instances/140-internal-swarm/lib/app-builder.py}
  touch $out
''
