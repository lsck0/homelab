# the energy model, the meter guard and the feed scripts in the sandbox: feeds_test.py (units, properties,
# fault injection at urlopen), flake8 over the area's python, promtool over the inverter exporter's output.
# $out/payloads holds what each feed publishes, for trmnl-templates.nix and 105's dashboards.nix
{ pkgs, lib, ... }:
let
  energyModel = import ../../../modules/energy { inherit pkgs; };
  feedIo = import ../../../modules/feeds { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    energyModel feedIo ps.hypothesis ps.jinja2 ps.icalendar ps.recurring-ical-events ps.tzdata ps.flake8
  ]);
  # the lab's line width; the scripts are linted the same way when nix builds them
  lineMax = 150;
  froniusExporter = ../../105-internal-grafana/lib/fronius-exporter.py;
  # what feeds_test.py loads by name: this terminal's feeds and vm-105's spot price export
  scripts = [
    ../lib/energy-sync.py ../lib/stats-sync.py ../lib/calendar-sync.py ../lib/github-sync.py ../lib/arxiv-sync.py
    ../lib/trmnl-sync.py ../../105-internal-grafana/lib/spot-price.py
  ];
  scriptsDir = pkgs.linkFarm "feed-scripts" (map (path: { name = baseNameOf path; inherit path; }) scripts);
  sources = scripts ++ [
    ../../../modules/energy/lib/energy_model.py ../../../modules/feeds/lib/feed_io.py froniusExporter ./feeds_test.py
    ../../105-internal-grafana/lib/dashboards/grafana.py ../../105-internal-grafana/lib/dashboards/energy.py
    ../../105-internal-grafana/lib/dashboards/homelab.py ../../105-internal-grafana/lib/dashboards/service.py
  ];
in
pkgs.runCommand "feeds" { nativeBuildInputs = [ python pkgs.prometheus.cli ]; } ''
  python3 -m flake8 --max-line-length ${toString lineMax} ${lib.concatMapStringsSep " " (source: "${source}") sources}
  python3 ${./feeds_test.py} ${scriptsDir} ${froniusExporter} ${../../125-internal-homeassistant/lib/meter_reading.jinja} $out
  for exposition in $out/fronius-*.prom; do
    promtool check metrics < "$exposition"
  done
''
