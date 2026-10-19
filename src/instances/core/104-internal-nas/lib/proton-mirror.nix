# proton-mirror.nu with its tools: one derivation for the units and their test; the units put proton's cli on the
# path, the test a fake one
{ pkgs }:
let
  repair = import ./proton-events-lock-repair.nix { inherit pkgs; };
in
pkgs.writers.writeNuBin "proton-mirror" {
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.findutils
      pkgs.util-linux
      repair
    ])
  ];
} (builtins.readFile ./source-guard.nu + builtins.readFile ./proton-mirror.nu)
