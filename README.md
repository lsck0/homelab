# Homelab

```sh
git clone https://github.com/lsck0/homelab
cd homelab
```

Needs nix (flakes), terraform, sops and jq. The sops age key is owned by the
dotfiles repo at `~/projects/arch-dotfiles/configs/secrets/age.txt`;
`secrets/age.txt` is a symlink to it that `init.sh` and `sync.sh` create.

## Bootstrap

```sh
src/scripts/init.sh <proxmox-ip>   # proxmox api token, tfvars, secrets, golden image
src/scripts/hermes-secrets.sh      # hermes ssh key, anthropic api key, telegram bot
src/scripts/secrets-sync.sh        # reconcile src/secrets.json with what the configs read
```

## Run

```sh
./sync.sh                                                   # deploy everything
nix build ./src#checks.x86_64-linux.<test>                  # nixos vm tests: on-demand kopia swarm minecraft monitoring
src/tests/media-stack.sh                                    # media stack against the real containers (docker)
src/tests/hermes-agent.sh                                   # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
src/scripts/secrets-sync.sh [--apply]                       # add missing secrets, drop unused ones
sudo src/scripts/setup-dns.sh                               # workstation: resolve *.lsck0.dev through the lab dns
src/scripts/deinit.sh                                       # tear the lab down again
src/scripts/stack.sh status                                 # which VM groups are on
src/scripts/stack.sh {media|apps} {on|off|onDemand} [--apply] # swap a group in or out (the box cannot host all of them)
```
