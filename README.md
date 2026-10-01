# Homelab

```sh
git clone https://github.com/lsck0/homelab
cd homelab
```

Needs nix (flakes), terraform, sops, age, jq and openssl; sshpass only for Proxmox password auth,
gh, python3 and curl for `hermes-secrets.sh`, docker for the e2e tests. The sops age key is owned by the
dotfiles repo at `~/projects/arch-dotfiles/configs/secrets/age.txt`; `secrets/age.txt` is a symlink to it
that `init.sh` and `sync.sh` create, and `sync.sh` unlocks it with the YubiKey
(`~/projects/arch-dotfiles/scripts/yubikey.sh unlock`) when it is locked.

Every key in `src/keys/` is authorized on every guest, the router and Proxmox root, so the deploying
machine's `~/.ssh/id_ed25519.pub` must be one of them.

## Bootstrap

```sh
src/scripts/init.sh <proxmox-ip>   # proxmox api tokens, tfvars, secrets, golden image
src/scripts/hermes-secrets.sh      # hermes ssh key, github app, anthropic api key, telegram bot
```

## Run

```sh
./sync.sh                                                     # deploy everything
nix build ./src#checks.x86_64-linux.<test>                    # nixos vm tests: on-demand kopia swarm minecraft monitoring
src/tests/media-stack.sh                                      # media stack against the real containers (docker)
src/tests/hermes-agent.sh                                     # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
src/scripts/secrets-sync.sh [--apply [--prune]]               # add missing secrets; --prune drops unused ones
sudo src/scripts/setup-dns.sh                                 # workstation: resolve *.lsck0.dev through the lab dns
src/scripts/deinit.sh [--yes] [proxmox-ip]                    # tear the lab down again
src/scripts/stack.sh status                                   # which VM groups are on
src/scripts/stack.sh {media|apps} {on|off|onDemand} [--apply] # swap a group in or out (the box cannot host all of them)
```
