# `nix fmt` (formatter.nu) with its tools; the format check runs the same one
{
  pkgs,
  lib,
  terraform,
}:
pkgs.writers.writeNuBin "lab-format" {
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      pkgs.git
      pkgs.nixfmt
      pkgs.ruff
      pkgs.go
      terraform
    ])
  ];
} ./formatter.nu
