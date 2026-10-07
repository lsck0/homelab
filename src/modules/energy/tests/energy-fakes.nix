# the price api fake its users' tests share (energy_fakes.py): linted at the lab's width, and its answer is what
# energy_model parses, every quarter hour of the asked local days
{ pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ (import ../default.nix { inherit pkgs; }) ps.flake8 ]);
  # the lab's line width
  lineMax = 150;
in
pkgs.runCommand "energy-fakes" { nativeBuildInputs = [ python ]; } ''
  python3 -m flake8 --max-line-length ${toString lineMax} ${./energy_fakes.py} ${../lib/energy_model.py}
  PYTHONPATH=${./.} python3 -c '
  import datetime
  import energy_model as em
  from energy_fakes import FakeSpot
  day = datetime.date(2026, 3, 29)
  slots = em.spot_fetch(FakeSpot(), "http://spot.test/price", em.SPOT_ZONE, day, day)
  assert len(slots) == 23 * 4, len(slots)
  assert em.spot_fetch(FakeSpot(fail=True), "http://spot.test/price", em.SPOT_ZONE, day, day) is None
  '
  touch $out
''
