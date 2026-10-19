# vm-112's package list (lib/archrepo-list.nu) against fixture arch-dotfiles trees and sync dbs, and publish's
# completeness gate over it (archrepo_list_test.nu)
{ pkgs, lib, ... }:
let
  tree = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ./archrepo_list_test.nu
      ../lib/archrepo-list.nu
      ../lib/archrepo-build.nu
    ];
  };
in
pkgs.runCommand "archrepo-list"
  {
    nativeBuildInputs = [
      pkgs.nushell
      pkgs.bash
      pkgs.coreutils
      pkgs.libarchive
    ];
  }
  ''
    nu --no-config-file ${tree}/tests/archrepo_list_test.nu
    touch $out
  ''
