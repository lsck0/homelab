# Homelab

Proxmox host, one NixOS VM per service. Terraform creates the VMs, a Nix flake
builds their configs, `./sync.sh` applies both and commits the result.

- `src/instances.tf`: every VM with its id, `enabled` (`true` / `"onDemand"` / `false`), cooldown and size
- `src/instances/<id>-<zone>-<service>.nix`: the NixOS config of that VM
- `src/modules/routes.nix`: every `*.lsck0.dev` hostname, the VM/port behind it, how it is authenticated and which lldap group may reach it
- `src/modules/hermes/skills/`: what Hermes (Telegram bot, root on the lab) knows how to do

Internal services live in `10.100.0.0/24` behind Traefik + Authelia, public ones
in the `10.200.0.0/24` DMZ behind Traefik + CrowdSec. The VM id is the last octet
of its IP.

## Identity

lldap (vm-102) is the only account store; Authelia (vm-101) is the only login.
Nothing internal is reachable without one of them:

- `auth = "sso"` routes get Authelia ForwardAuth. The route's `group` says which
  lldap group may enter, so **granting or revoking a service for a person is a
  group edit in the lldap dashboard** and takes effect within a minute.
- `auth = "own"` routes run their own login backed by the same directory:
  Forgejo, Nextcloud, Vaultwarden and Audiobookshelf through Authelia OIDC,
  Jellyfin by binding to lldap directly (its apps cannot follow a portal
  redirect).
- `auth = "token"` routes are headless (a Nix client, the Docker registry) and
  are not relayed from the internet at all.

Services whose built-in login is switched off also have their port restricted to
the ingress (`homelab.ingressOnly`), so Authelia cannot be skipped by calling a
VM directly from the LAN.

## Clone

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
nix build ./src#checks.x86_64-linux.<test>                  # nixos vm tests: on-demand kopia swarm minecraft monitoring renumber
src/tests/media-stack.sh                                    # media stack against the real containers (docker)
src/tests/hermes-agent.sh                                   # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
src/scripts/secrets-sync.sh [--apply]                       # add missing secrets, drop unused ones
src/scripts/stack.sh status                                 # which VM groups are on
src/scripts/stack.sh {media|apps|gpu} {on|off} [--apply]     # swap a group in or out (the box cannot host all of them)
src/scripts/renumber.sh [--execute]                         # rename vm ids on proxmox to match instances.tf
```

## CI runners

Two kinds, both internal:

- **Forgejo** (vm-115): one runner for `git.lsck0.dev`.
- **GitHub** (vm-116): one ephemeral runner per replica, registered straight to a
  repo. Add or remove a repo by editing the `repos` attribute set at the top of
  `src/instances/116-internal-github-runner.nix` (`<owner>/<repo> = <parallel
  jobs>`) and running `./sync.sh`. Target them with
  `runs-on: [self-hosted, nixos]`.

  Each job gets a freshly registered runner and a wiped state directory, then the
  runner de-registers itself. Registration uses a fine-grained PAT
  (`github-runner-token` in sops) with *Administration: read and write* on those
  repos.

## Backups

Kopia (vm-106) snapshots `/srv/nas` nightly at 02:00. A file-level snapshot of a
live database is not a backup, so every database dumps itself to
`/srv/nas/data/db-dumps/<vm>/` at 01:30 first (`src/modules/db-backup.nix`):
SQLite through `.backup`, Postgres through `pg_dump`. That also covers the two
things whose state is on local disk and not on the NAS at all — the Authelia
second-factor enrolments and the whole lldap directory.

Restore with `nas-restore` on vm-106 (`nas-restore` with no arguments prints the
usage).
