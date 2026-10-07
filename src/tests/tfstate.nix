# lab-wide: sync.sh's terraform state (scripts/lib/tfstate.sh)
# sync.sh's terraform state handling (scripts/lib/tfstate.sh) in the sandbox: the pull and push table, the nas lock,
# and a seeded simulation of two deployers with failing pushes and nas outages (tfstate_test.sh). No network.
{ pkgs, seed ? 1, ... }:
pkgs.runCommand "tfstate-seed-${toString seed}" {
  nativeBuildInputs = with pkgs; [ bash jq coreutils util-linux gnugrep diffutils ];
  passthru.regressionSeeds = [ ];
} ''
  bash ${./tfstate_test.sh} ${../scripts/lib/tfstate.sh} ${toString seed}
  touch $out
''
