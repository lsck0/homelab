# Homelab

Proxmox host, one NixOS VM per service. Terraform creates the VMs, a Nix flake
builds their configs, `just sync` applies both and commits the result.

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

Needs nix (flakes), terraform, sops, jq, just, and the age key at `secrets/age.txt`.

## Bootstrap

```sh
src/scripts/init.sh <proxmox-ip>   # proxmox api token, tfvars, secrets, golden image
just secrets-hermes                # hermes ssh key, anthropic api key, telegram bot
```

## Run

```sh
just            # list commands
just sync       # deploy everything
just check      # static checks
just test       # all tests: nixos vm tests, media stack (docker), hermes scenarios
```
