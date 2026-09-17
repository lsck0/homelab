# homelab entry point: run `just` to list everything.

set shell := ["bash", "-euo", "pipefail", "-c"]

nix := "nix --extra-experimental-features 'nix-command flakes'"
vm_tests := "on-demand kopia swarm minecraft monitoring renumber"

# list commands
default:
    @just --list --unsorted

# apply terraform, build and deploy every VM, commit the generation
sync:
    ./sync.sh

# one-time VM renumbering migration (dry run unless --execute)
renumber *args:
    src/scripts/renumber.sh {{args}}

# fill the secrets Hermes needs (ssh key, api key, telegram)
secrets-hermes:
    src/scripts/hermes-secrets.sh

# static checks: eval every host, terraform validate, shellcheck, deadnix, secret scan of staged changes
check:
    {{nix}} eval --no-warn-dirty --json --impure --expr 'let f = builtins.getFlake (toString ./src); in builtins.mapAttrs (n: c: c.config.system.build.toplevel.drvPath) f.nixosConfigurations' > /dev/null
    terraform -chdir=src validate -no-color
    {{nix}} shell --inputs-from ./src nixpkgs#shellcheck -c shellcheck -S warning sync.sh src/scripts/*.sh src/tests/*.sh
    {{nix}} shell --inputs-from ./src nixpkgs#deadnix -c deadnix --fail --no-lambda-pattern-names src
    {{nix}} shell --inputs-from ./src nixpkgs#gitleaks -c gitleaks git --pre-commit --staged --no-banner --redact .

# nixos vm tests, all or one of: on-demand kopia swarm minecraft monitoring renumber
test-vm name="":
    for t in {{ if name == "" { vm_tests } else { name } }}; do {{nix}} build --no-link -L ./src#checks.x86_64-linux.$t; done

# media stack against the real app containers (docker)
test-media:
    src/tests/media-stack.sh

# hermes agent scenarios (free nous model, or ANTHROPIC_API_KEY for the production model)
test-hermes *scenarios:
    src/tests/hermes-agent.sh {{scenarios}}

# everything
test: check test-vm test-media test-hermes
