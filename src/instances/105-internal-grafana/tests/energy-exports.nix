# the fronius exporter and the spot price export in the sandbox (energy_exports_test.py), flake8 over vm-105's python,
# promtool over the exporter's output; $out holds that output for dashboards.nix
{ pkgs, lib, ... }:
let
  python = pkgs.python3.withPackages (ps: [
    (import ../../../modules/energy { inherit pkgs; }) (import ../../../modules/feeds { inherit pkgs; }) ps.flake8
  ]);
  # the lab's line width; the scripts are linted the same way when nix builds them
  lineMax = 150;
  froniusExporter = ../lib/fronius-exporter.py;
  spotPrice = ../lib/spot-price.py;
  sources = [
    froniusExporter spotPrice ./energy_exports_test.py
    ../lib/dashboards/grafana.py ../lib/dashboards/energy.py ../lib/dashboards/homelab.py ../lib/dashboards/service.py
  ];
in
pkgs.runCommand "energy-exports" { nativeBuildInputs = [ python pkgs.prometheus.cli ]; } ''
  python3 -m flake8 --max-line-length ${toString lineMax} ${lib.concatMapStringsSep " " (source: "${source}") sources}
  mkdir -p $out
  python3 ${./energy_exports_test.py} ${froniusExporter} ${spotPrice} $out
  for exposition in $out/fronius-*.prom; do
    promtool check metrics < "$exposition"
  done
''
