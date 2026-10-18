# archmirror-sync.nu with its tools: one derivation for the unit and its test
{ pkgs }:
pkgs.writers.writeNuBin "archmirror-sync" {
  makeWrapperArgs = [ "--prefix" "PATH" ":" (pkgs.lib.makeBinPath [ pkgs.rsync pkgs.coreutils ]) ];
} (builtins.readFile ./archmirror-sync.nu)
