# the textfile prune (lib/prune.nu) across generations (prune_test.nu). No vm.
{ pkgs, ... }:
pkgs.runCommand "textfile-prune"
  {
    nativeBuildInputs = [
      pkgs.nushell
      pkgs.coreutils
    ];
  }
  ''
    export HOME=$TMPDIR
    nu --no-config-file ${./prune_test.nu} ${pkgs.writers.writeNu "textfile-prune" ../lib/prune.nu}
    touch $out
  ''
