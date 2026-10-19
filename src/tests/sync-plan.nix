# lab-wide: sync.nu's own decisions (sync_plan_test.nu)
# which guests a run names, the order it deploys them in, and its read-back of the Proxmox anti-spoofing rules, with
# systemctl and nft stubbed. sync.nu lives at the repo's top, which only a git flake (git+file:...?dir=src) holds; a
# path: flake is refused. No network.
{ pkgs, lib, ... }:
let
  repo = ../..;
  tree = lib.fileset.toSource {
    root = repo;
    fileset = lib.fileset.unions [
      (repo + "/sync.nu")
      ../scripts/lib
      ./sync_plan_test.nu
    ];
  };
in
assert lib.assertMsg (builtins.pathExists (repo + "/sync.nu"))
  "sync-plan needs the whole repo (sync.nu): build it from git, `nix build ./src#checks.x86_64-linux.sync-plan`, not from a path: flake";
pkgs.runCommand "sync-plan"
  {
    nativeBuildInputs = [
      pkgs.nushell
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    export HOME=$TMPDIR
    nu --no-config-file ${tree}/src/tests/sync_plan_test.nu ${tree}
    touch $out
  ''
