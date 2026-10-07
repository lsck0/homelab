# the textfile prune (lib/prune.sh) across generations: a stale metric of a removed or moved writer goes, a file no
# generation declared stays (prune_test.sh). No vm.
{ pkgs, ... }:
pkgs.runCommand "textfile-prune" { nativeBuildInputs = [ pkgs.bash pkgs.coreutils ]; } ''
  bash ${./prune_test.sh} ${../lib/prune.sh}
  touch $out
''
