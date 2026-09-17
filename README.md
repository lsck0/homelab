# Homelab

Proxmox host, one NixOS VM per service. Terraform creates the VMs, a Nix flake
builds their configs, `./sync.sh` applies both and commits the result.

- `src/instances.tf`: every VM with its id, `enabled` (`true` / `"onDemand"` / `false`), cooldown and size
- `src/instances/<id>-<zone>-<service>.nix`: the NixOS config of that VM
- `src/modules/routes.nix`: every `*.lsck0.dev` hostname and the VM/port behind it
- `src/modules/hermes/skills/`: what Hermes (Telegram bot, root on the lab) knows how to do

Internal services live in `10.100.0.0/24` behind Traefik + Authelia, public ones
in the `10.200.0.0/24` DMZ behind Traefik + CrowdSec. The VM id is the last octet
of its IP.

## Clone

```sh
git clone https://github.com/lsck0/homelab
cd homelab
```

Needs nix (flakes), terraform, sops, jq, and the age key at `secrets/age.txt`.

## Bootstrap

```sh
src/scripts/init.sh <proxmox-ip>   # proxmox api token, tfvars, secrets, golden image
src/scripts/hermes-secrets.sh      # hermes ssh key, anthropic api key, telegram bot
```

## Run

```sh
./sync.sh                                                   # deploy everything
nix build ./src#checks.x86_64-linux.<test>                  # nixos vm tests: on-demand kopia swarm minecraft monitoring renumber
src/tests/media-stack.sh                                    # media stack against the real containers (docker)
src/tests/hermes-agent.sh                                   # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
src/scripts/renumber.sh [--execute]                         # rename vm ids on proxmox to match instances.tf
```
