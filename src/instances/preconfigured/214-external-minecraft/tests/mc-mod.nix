# vm-214's mc-mod (lib/mc-mod.nu): the version ranges, the jar metadata and the refusals (mc_mod_test.nu)
{ pkgs, lib, ... }:
let
  tree = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./mc_mod_test.nu
      ../lib/mc-mod.nu
    ];
  };
in
pkgs.runCommand "mc-mod"
  {
    nativeBuildInputs = [
      pkgs.nushell
      pkgs.unzip
      pkgs.zip
    ];
  }
  ''
    export HOME=$TMPDIR
    nu --no-config-file ${tree}/tests/mc_mod_test.nu
    touch $out
  ''
