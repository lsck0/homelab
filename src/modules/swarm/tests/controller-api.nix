# the controller's door on every swarm manager (lib/controller-api.py), request by request: who may start what
{ pkgs, ... }:
pkgs.runCommand "controller-api" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./controller_api_test.py} ${../lib/controller-api.py}
  touch $out
''
