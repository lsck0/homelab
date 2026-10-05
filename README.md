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

`src/secrets.json` is the one secrets file a human edits (`sops src/secrets.json`). Every guest gets its own
age key and `src/host-secrets/<host>.json`, holding only the secrets its config reads; `sync.sh` regenerates
both through `src/scripts/secrets-hosts.sh`. Plaintext never touches the repo: write sops files with
`src/scripts/sops-encrypt.sh`, and the pre-commit hook (`.githooks`, set by `sync.sh`) refuses a commit that
holds one unencrypted.

Rotating the admin key (it sat on every guest until per-host keys existed): make a new age key in the dotfiles
secrets, put its public half in `ADMIN_RECIPIENTS` of `src/scripts/secrets-hosts.sh`, run that script with the old
key still unlocked (it re-keys every file), then change each secret's value with `sops src/secrets.json` and
`./sync.sh`. A generation from before per-host keys cannot be rolled back to: its guests expect the admin key.

## Apps

An app is a GitHub repo and a branch in `src/modules/apps.nix`. vm-117 builds every new commit, parks the
images in `registry.lsck0.dev` and deploys them to the swarm (manager vm-140, workers vm-150 to vm-152 in the
apps zone) behind the edge at `<app>.lsck0.dev`. Enable one, then `src/scripts/secrets-sync.sh --apply` if it
declares secrets, then `./sync.sh`.

## Bootstrap

```sh
src/scripts/init.sh <proxmox-ip>   # proxmox api tokens, tfvars, secrets, golden image
src/scripts/hermes-secrets.sh      # hermes ssh key, github app, anthropic api key, telegram bot
```

## Run

```sh
./sync.sh                                                     # deploy everything
TF_STATE_FRESH=1 ./sync.sh                                    # first deploy only: no terraform state on the nas yet
nix build ./src#checks.x86_64-linux.<test>                    # nixos vm tests: on-demand kopia swarm swarm-render minecraft monitoring auth-chain
src/tests/media-stack.sh                                      # media stack against the real containers (docker)
src/tests/hermes-agent.sh                                     # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
src/scripts/secrets-sync.sh [--apply [--prune]]               # add missing secrets; --prune drops unused ones
src/scripts/secrets-hosts.sh                                  # per-host keys and secret files (sync.sh runs it)
sudo src/scripts/setup-dns.sh                                 # workstation: resolve *.lsck0.dev through the lab dns
src/scripts/deinit.sh [--yes] [proxmox-ip]                    # tear the lab down again
src/scripts/stack.sh status                                   # which VM groups are on
src/scripts/stack.sh {media|apps} {on|off|onDemand} [--apply] # swap a group in or out (the box cannot host all of them)
```
