# proton-bisync.sh with its tools, shellchecked at build: one derivation for the units, the login and the test
{ pkgs }:
pkgs.writeShellApplication {
  name = "proton-bisync";
  runtimeInputs = with pkgs; [ coreutils findutils gnugrep rclone util-linux ];
  text = builtins.readFile ./source-guard.sh + builtins.readFile ./proton-bisync.sh;
}
