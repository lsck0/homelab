# lab-wide: the pre-commit hook and scripts/secrets-check.sh, the workstation's guard
# the plaintext guard (scripts/secrets-check.sh) as the pre-commit hook runs it, in the sandbox: one scratch repo
# per case, each commit refused or accepted as secrets_check_test.sh's table says. Throwaway age key, no network.
# The hook lives at the repo's top, which only a git flake (git+file:...?dir=src) holds; a path: flake is refused, as
# by the shellcheck check.
{ pkgs, lib, ... }:
let
  # the hook, the guard and what it sources; the sandbox has no /usr/bin/env
  fixture = pkgs.runCommand "secrets-check-fixture" { } ''
    cp -r ${lib.fileset.toSource {
      root = ../..;
      fileset = lib.fileset.unions [
        ../../.githooks
        ../scripts/secrets-check.sh
        ../scripts/sops-encrypt.sh
        ../scripts/lib
      ];
    }} $out
    chmod -R u+w $out
    patchShebangs $out
  '';
in
assert lib.assertMsg (builtins.pathExists ../../.githooks)
  "secrets-check needs the whole repo (.githooks): build it from git, `nix build ./src#checks.x86_64-linux.secrets-check`, not from a path: flake";
pkgs.runCommand "secrets-check" {
  nativeBuildInputs = with pkgs; [ bash sops age jq git coreutils findutils gnused gnugrep ];
} ''
  export HOME=$TMPDIR
  bash ${./secrets_check_test.sh} ${fixture}
  touch $out
''
