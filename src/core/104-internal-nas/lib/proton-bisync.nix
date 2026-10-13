# proton-bisync.sh over its engine (proton-bisync.py), shellchecked and flake8-checked at build: one derivation for
# the units and the test; the units hand it proton's cli, the test a fake one (PROTON_BISYNC_CLI)
{ pkgs }:
let
  engine = pkgs.writers.writePython3Bin "proton-bisync-engine" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./proton-bisync.py);
in
pkgs.writeShellApplication {
  name = "proton-bisync";
  runtimeInputs = with pkgs; [ coreutils findutils util-linux engine ];
  text = builtins.readFile ./source-guard.sh + builtins.readFile ./proton-bisync.sh;
}
