# the import of an app's own dashboards by the builder (lib/dashboards-import.py), table by table
{ pkgs, ... }:
pkgs.runCommand "dashboards-import" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./dashboards_import_test.py} ${../lib/dashboards-import.py}
  touch $out
''
