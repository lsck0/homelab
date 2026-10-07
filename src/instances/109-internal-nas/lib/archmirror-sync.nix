# archmirror-sync.sh with its tools, shellchecked at build: one derivation for the unit and its test
{ pkgs }:
pkgs.writeShellApplication {
  name = "archmirror-sync";
  runtimeInputs = [ pkgs.rsync pkgs.coreutils pkgs.diffutils ];
  text = builtins.readFile ./archmirror-sync.sh;
}
