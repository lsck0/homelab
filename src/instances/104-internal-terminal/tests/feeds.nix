# the energy model and this terminal's feed scripts in the sandbox: feeds_test.py (units, properties, fault injection
# at urlopen), flake8 over the area's python. $out/payloads holds what each feed publishes, for trmnl-templates.nix
{ pkgs, lib, ... }:
let
  energyModel = import ../../../modules/energy { inherit pkgs; };
  feedIo = import ../../../modules/feeds { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    energyModel feedIo ps.hypothesis ps.icalendar ps.recurring-ical-events ps.tzdata ps.flake8
  ]);
  # the lab's line width; the scripts are linted the same way when nix builds them
  lineMax = 150;
  # the price api's fake, shared with 105-internal-grafana's spot price test
  fakes = ../../../modules/energy/tests;
  scripts = [
    ../lib/energy-sync.py ../lib/stats-sync.py ../lib/calendar-sync.py ../lib/github-sync.py ../lib/arxiv-sync.py
    ../lib/trmnl-sync.py
  ];
  scriptsDir = pkgs.linkFarm "feed-scripts" (map (path: { name = baseNameOf path; inherit path; }) scripts);
  sources = scripts ++ [
    ../../../modules/energy/lib/energy_model.py ../../../modules/feeds/lib/feed_io.py "${fakes}/energy_fakes.py" ./feeds_test.py
  ];
in
pkgs.runCommand "feeds" { nativeBuildInputs = [ python ]; } ''
  python3 -m flake8 --max-line-length ${toString lineMax} ${lib.concatMapStringsSep " " (source: "${source}") sources}
  PYTHONPATH=${fakes} python3 ${./feeds_test.py} ${scriptsDir} $out
''
