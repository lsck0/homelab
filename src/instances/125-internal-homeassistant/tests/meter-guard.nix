# the meter guard macro home assistant renders for every typed-in reading (meter_guard_test.py), linted at the lab's width
{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ ps.jinja2 ps.hypothesis ps.flake8 ]);
  # the lab's line width
  lineMax = 150;
in
pkgs.runCommand "meter-guard" { nativeBuildInputs = [ python ]; } ''
  export HOME=$TMPDIR
  python3 -m flake8 --max-line-length ${toString lineMax} ${./meter_guard_test.py}
  python3 ${./meter_guard_test.py} ${../lib/meter_reading.jinja}
  touch $out
''
