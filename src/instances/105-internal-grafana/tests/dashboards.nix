# the boards 105-internal-grafana provisions, the lab's and every app's, as built (tests/dashboards_test.py): layout,
# refIds, every PromQL query parsed by promtool, and the energy board reading only metrics something in the repo writes
{ pkgs, lib, inputs, specialArgs, ... }:
let
  # the real vm-105, with the template app enabled so its board and its rules are built too, and an app serving tcp
  fixtureApp = "wat";
  tcpApp = {
    enable = true;
    repo = "lsck0/arcade";
    branch = "master";
    routes.arcade = { protocol = "tcp"; publicPort = 25565; port = 20199; };
  };
  hostWith = import ../../../tests/lib/host-with.nix { inherit inputs; };
  grafana = hostWith (specialArgs.lab.withApps (apps: lib.recursiveUpdate apps { ${fixtureApp}.enable = true; arcade = tcpApp; }))
    "105-internal-grafana";
  boards = lib.mapAttrsToList (_: entry: entry.source)
    (lib.filterAttrs (path: _: lib.hasPrefix "grafana-dashboards/" path || lib.hasPrefix "grafana-apps/" path) grafana.environment.etc);
  # the inverter exporter's real output, from 104-internal-terminal/tests/feeds.nix
  feeds = import ../../104-internal-terminal/tests/feeds.nix { inherit pkgs lib; };
  python = pkgs.python3.withPackages (_: [ (import ../../../modules/energy { inherit pkgs; }) ]);
in
pkgs.runCommand "dashboards" { nativeBuildInputs = [ python pkgs.prometheus.cli ]; } ''
  mkdir -p $out
  python3 ${./dashboards_test.py} $out ${feeds} ${../lib/spot-price.py} ${lib.concatMapStringsSep " " (board: "${board}") boards}
  promtool check rules $out/queries.json
''
