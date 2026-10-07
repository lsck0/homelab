# lab-wide: the pre-commit hook and scripts/secrets-check.sh, the workstation's guard
# the plaintext guard (scripts/secrets-check.sh) as the pre-commit hook runs it, in the sandbox: one scratch repo
# per case, each commit refused or accepted as secrets_check_test.sh's table says. Throwaway age key, no network.
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
pkgs.runCommand "secrets-check" {
  nativeBuildInputs = with pkgs; [ bash sops age jq git coreutils findutils gnused gnugrep ];
} ''
  export HOME=$TMPDIR
  bash ${./secrets_check_test.sh} ${fixture}
  touch $out
''
