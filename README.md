# Homelab

One Proxmox host running a lab of NixOS guests, declared entirely in this repo: a router with a leg in every zone,
two ingresses, sso, telemetry, a nas with off-site backups, a swarm for the owner's apps and the third-party services
on top. `./sync.nu` converges the host, the guests and the secrets from the tree; nothing is set by hand on a guest.
Every script is nushell. FEATURES.md lists what the lab does and holds the runbooks.

## Quick start

```sh
git clone https://github.com/lsck0/homelab && cd homelab
nix develop ./src                     # every tool, pinned by src/flake.lock (docker only for the e2e scripts)
src/scripts/init.nu <proxmox-ip>      # once: pin the host key, site, secrets, golden image, converge the host
TF_STATE_FRESH=1 ./sync.nu            # the first deploy: no terraform state on the nas yet
./sync.nu --dry-run                   # evaluate, build and print the plan, touching nothing
./sync.nu                             # every deploy after; ends in a `Generation: <n>` commit
./sync.nu <guest>... --skip-host      # the named guests (vmid or name) alone, or no host and terraform; no commit
src/scripts/init.nu <proxmox-ip> --upgrade   # apt full-upgrade of the host; it names the kernel a reboot starts
```

`terraform-law` and `policy-eval` gate every run: a broken law stops it before anything is applied. The sops age key
is the dotfiles' `~/projects/arch-dotfiles/configs/secrets/keys/age.txt`; `init.nu` and `sync.nu` keep `secrets/age.txt` linked to
it, and `sync.nu` unlocks it with the YubiKey (`dot secrets unlock`). The deploying machine's `~/.ssh/id_ed25519.pub`
must be one of `src/secrets/keys/`, which every guest, the router and Proxmox root authorize. Proxmox root takes keys
alone over ssh: leave `init.nu`'s password prompt blank on a converged host. root@pam logs in to the web ui with TOTP
or WebAuthn, its recovery keys kept offline.

| variable | effect |
|---|---|
| `HOMELAB_PARALLEL` | how many guests deploy at once |
| `TF_STATE_FRESH=1` | start an empty lab: set the local state copy aside, never touch the nas |
| `TF_STATE_OFFLINE=1` | the nas is down: apply from the local state copy |
| `DOTFILES`, `DOTFILES_SECRETS` | where the dotfiles checkout and its secrets directory are |
| `SOPS_AGE_KEY_FILE` | another admin key, e.g. during a rotation |

## Layout

```
sync.nu                       deploy everything
src/
  flake.nix                   hosts, checks and the `lab` facts, discovered from the folders below
  instances/
    core/<vmid>-<zone>-<service>/
                              a guest the lab needs: main.nix, instance.nix, lib/, tests/, skill.md, its secrets
    core/swarm.nix            the shared swarm: state worker, ports, worker shape
    preconfigured/<vmid>-<zone>-<service>/
                              a third-party service the lab runs, the same folder
    custom/<name>/            an app of the owner's own: app.nix, secrets, lib/, tests/
  modules/                    the platform: what two or more guests use
  scripts/                    init, deinit, stack, secrets-sync, secrets-check, sops-encrypt, pve-install; lib/
  tests/                      the harness (lib/, stubs/), policy/ (the lab's laws) and the lab-wide tests
  terraform/                  the guests and the Proxmox firewall, from `nix eval .#lab.terraform`
  generated/                  what the scripts write: site.json, known_hosts, zones.json, lab.json, onions.json
```

Zones by vmid: internal 1xx (staff only, behind authelia), external 200-249 (public, behind the edge), apps swarm
workers 250 and up, the router 300. No zone reaches the house or another zone but through a named flow
(`src/modules/flows.nix`); a guest's ssh answers the operators alone, its node exporter vm-103. Every file has one owner
folder; what two or more instances use is a module.

## Adding an instance

Copy `src/instances/preconfigured/_template/` to `src/instances/preconfigured/<vmid>-<zone>-<service>/` (or under
`src/instances/core/` when the lab needs it), fill in `main.nix` and `instance.nix`, `git add` it, `./sync.nu`.
Terraform makes a vm or an unprivileged lxc as `vm.needs` decides; the ingress, authelia, the homepage, the prober and
the router pick up its services. Features are off until named in a service's `on` (`src/modules/profiles.nix`).

## Adding an app

Copy `src/instances/custom/_template/` to `src/instances/custom/<name>/`: a repo and a branch are enough. `git add`,
`./sync.nu`. vm-107 builds every new commit (Dockerfile, compose file or `static`), pushes to `registry.lsck0.dev`
and deploys it at `<name>.lsck0.dev` on the edge; the options are in `src/modules/apps-catalog`.

## Secrets

A secret lives next to what reads it: `secrets.<name> = "<kind>";` in the reading guest's `instance.nix` (or app.nix),
or in `src/secrets/shared.nix` when several read it; the value is in that folder's `secrets.sops.json`. `./sync.nu`
runs `src/scripts/secrets-sync.nu --apply`, which generates missing values and hands each guest only its own age
key. Write sops files with `src/scripts/sops-encrypt.nu`; the pre-commit hook refuses plaintext. Rotating the admin
key: FEATURES.md, Secrets.

## Recovery

- A guest recreated or its age key lost: `./sync.nu` re-pins and rewrites it. Proxmox reinstalled:
  `src/scripts/init.nu --pin <proxmox-ip>` after comparing the fingerprint on its console.
- A service's data broken: `ssh root@10.100.0.104 nas-restore service <share> <snapshot id or date> --yes`.
- Locked out by the Proxmox firewall: `ssh root@<proxmox> pve-firewall stop` from the workstation or the notebook
  (or the host's console), fix `site.json`, `./sync.nu`.
- The lab and the nas gone: restore the kopia repository from Proton Drive (FEATURES.md, Recovery).

## Tests

```sh
nix eval ./src#checks.x86_64-linux --apply builtins.attrNames                    # every check
nix build ./src#checks.x86_64-linux.<name> -L --no-link --max-jobs 1           # one check
nix build ./src#legacyPackages.x86_64-linux.seeded.<name>.<seed> -L --no-link   # one seed of a seeded test
```

Every `src/tests/<name>.nix` and every `tests/<name>.nix` of an instance or module is a check named by its file; a
new file needs `git add`. `policy-eval` holds the lab's laws over every real configuration.
