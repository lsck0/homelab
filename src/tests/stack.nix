# lab-wide: scripts/stack.sh, the workstation's power switch over every instance
# scripts/stack.sh over the real instance files in the sandbox: each phase and state edits only that phase's guests
# (stack_test.py)
{ pkgs, lib, ... }:
let
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.name == "instance.nix") ../instances)
      ../apps/swarm.nix
      ../modules/instance-schema.nix
      ../scripts/stack.sh
      ../scripts/lib/tools.sh
    ];
  };
in
pkgs.runCommand "stack" { nativeBuildInputs = [ pkgs.bash pkgs.python3 ]; } ''
  mkdir fixture && cp -r ${src} fixture/src && chmod -R u+w fixture
  python3 ${./stack_test.py} fixture
  touch $out
''
