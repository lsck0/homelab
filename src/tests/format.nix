# lab-wide: `nix fmt` changes nothing; on a diff, `nix fmt` from src/ writes it
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  formatter = inputs.self.formatter.${pkgs.stdenv.hostPlatform.system};
  sources = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (
      f:
      lib.any f.hasExt [
        "nix"
        "py"
        "go"
        "tf"
      ]
    ) ../.;
  };
in
pkgs.runCommand "format"
  {
    nativeBuildInputs = [
      formatter
      pkgs.diffutils
    ];
  }
  ''
    cp -r --no-preserve=mode ${sources} formatted
    lab-format "$PWD/formatted"
    diff -ru ${sources} formatted
    touch $out
  ''
