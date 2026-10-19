# lab-wide: sync.nu's terraform state (scripts/lib/tfstate.nu)
# the pull and push table, the nas lock, and a seeded simulation of two deployers with failing pushes and nas outages
# (tfstate_test.nu), on local files in the sandbox
{
  pkgs,
  lib,
  seed ? 1,
  ...
}:
let
  tree = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./tfstate_test.nu
      ../scripts/lib/tfstate.nu
    ];
  };
in
pkgs.runCommand "tfstate-seed-${toString seed}"
  {
    nativeBuildInputs = with pkgs; [
      nushell
      util-linux
      coreutils
    ];
    passthru.regressionSeeds = [ ];
  }
  ''
    export HOME=$TMPDIR
    nu --no-config-file ${tree}/tests/tfstate_test.nu ${toString seed}
    touch $out
  ''
