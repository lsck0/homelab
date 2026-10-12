# vm-105's own exporters in the sandbox (exporters_test.py): the inverter's and the spot price's, faults injected at
# their boundary, promtool over the inverter's output, flake8 over vm-105's python. $out holds the inverter's
# expositions, which tests/dashboards.nix reads as the metric names it writes
{ pkgs, lib, ... }:
let
  energyModel = import ../../../modules/energy { inherit pkgs; };
  feedIo = import ../../../modules/feeds { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [ energyModel feedIo ps.flake8 ]);
  # the lab's line width; the scripts are linted the same way when nix builds them
  lineMax = 150;
  # the price api's fake, shared with 104-internal-terminal's energy-sync test
  fakes = ../../../modules/energy/tests;
  sources = [
    ../lib/fronius-exporter.py ../lib/spot-price.py ./exporters_test.py
    ../lib/dashboards/grafana.py ../lib/dashboards/energy.py ../lib/dashboards/homelab.py ../lib/dashboards/service.py
  ];
in
pkgs.runCommand "exporters" { nativeBuildInputs = [ python pkgs.prometheus.cli ]; } ''
  mkdir -p $out
  python3 -m flake8 --max-line-length ${toString lineMax} ${lib.concatMapStringsSep " " (source: "${source}") sources}
  PYTHONPATH=${fakes} python3 ${./exporters_test.py} ${../lib/fronius-exporter.py} ${../lib/spot-price.py} $out
  for exposition in $out/fronius-*.prom; do
    promtool check metrics < "$exposition"
  done
''
