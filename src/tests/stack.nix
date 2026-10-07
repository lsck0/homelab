# lab-wide: scripts/stack.sh, the workstation's power switch over every instance
# scripts/stack.sh over the real instance files in the sandbox: each phase and state edits only that phase's guests,
# and the collector, evaluated again after each write, reports them in the wanted state (stack_test.py). `nix eval`
# is a stand-in that evaluates the collector alone with nix-instantiate: the sandbox holds no flake inputs.
{ pkgs, lib, ... }:
let
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (f: f.hasExt "nix" || f.hasExt "json" || f.hasExt "sh") ../.;
  };
  nixEval = pkgs.writeShellScriptBin "nix" ''
    # nix eval --json --no-warn-dirty <src>#lab.instances --apply <function>
    set -euo pipefail
    flake=$4
    exec nix-instantiate --eval --strict --json --store dummy:// \
      -E "(''${6}) (import ''${flake%#*}/modules/lab { lib = import ${pkgs.path}/lib; }).instances"
  '';
in
pkgs.runCommand "stack" { nativeBuildInputs = [ pkgs.bash pkgs.python3 pkgs.nix nixEval ]; } ''
  export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix
  mkdir fixture && cp -r ${src} fixture/src && chmod -R u+w fixture
  python3 ${./stack_test.py} fixture
  touch $out
''
