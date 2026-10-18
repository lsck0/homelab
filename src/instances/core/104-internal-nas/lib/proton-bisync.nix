# proton-bisync.nu over its engine (proton-bisync.py, flake8-checked at build): one derivation for the units and the
# test; the units hand it proton's cli, the test a fake one (PROTON_BISYNC_CLI)
{ pkgs }:
let
  engine = pkgs.writers.writePython3Bin "proton-bisync-engine" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./proton-bisync.py);
  repair = import ./proton-events-lock-repair.nix { inherit pkgs; };
in
pkgs.writers.writeNuBin "proton-bisync" {
  makeWrapperArgs = [ "--prefix" "PATH" ":" (pkgs.lib.makeBinPath [ pkgs.util-linux engine repair ]) ];
} (builtins.readFile ./source-guard.nu + builtins.readFile ./proton-bisync.nu)
