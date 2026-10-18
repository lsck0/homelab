# lab-wide: the pre-commit hook and scripts/secrets-check.nu, the workstation's guard
# the plaintext guard as the pre-commit hook runs it, in the sandbox: one scratch repo per case, each commit refused or
# accepted as secrets_check_test.nu's table says. Throwaway age key, no network. The hook lives at the repo's top,
# which only a git flake (git+file:...?dir=src) holds; a path: flake is refused.
{ pkgs, lib, ... }:
let
  fixture = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../.githooks
      ../scripts/secrets-check.nu
      ../scripts/sops-encrypt.nu
      ../scripts/lib
    ];
  };
in
assert lib.assertMsg (builtins.pathExists ../../.githooks)
  "secrets-check needs the whole repo (.githooks): build it from git, `nix build ./src#checks.x86_64-linux.secrets-check`, not from a path: flake";
pkgs.runCommand "secrets-check" {
  nativeBuildInputs = with pkgs; [ nushell sops age git coreutils ];
} ''
  export HOME=$TMPDIR
  # the hook's `/usr/bin/env nu` is the workstation's; the sandbox has neither
  cp -r ${fixture} fixture
  chmod -R u+w fixture
  patchShebangs fixture/.githooks
  nu --no-config-file ${./secrets_check_test.nu} "$PWD/fixture"
  touch $out
''
