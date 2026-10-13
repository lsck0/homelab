# proton-mirror.sh with its tools, shellchecked at build: one derivation for the unit and its test; the unit puts
# proton's cli on the path, the test a fake one
{ pkgs }:
pkgs.writeShellApplication {
  name = "proton-mirror";
  runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused jq util-linux ];
  text = builtins.readFile ./source-guard.sh + builtins.readFile ./proton-mirror.sh;
}
