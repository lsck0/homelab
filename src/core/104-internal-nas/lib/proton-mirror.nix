# proton-mirror.sh with its tools, shellchecked at build: one derivation for the units and their test; the units put
# proton's cli on the path, the test a fake one
{ pkgs }:
pkgs.writeShellApplication {
  name = "proton-mirror";
  runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused gawk jq rsync util-linux ];
  text = builtins.readFile ./proton-mirror.sh;
}
