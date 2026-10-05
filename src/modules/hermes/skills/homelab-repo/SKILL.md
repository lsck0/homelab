---
name: homelab-repo
description: Change the homelab config through pull requests on GitHub.
version: 1.1.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, NixOS, Terraform, GitOps]
    related_skills: [homelab-ops]
---

# The homelab repository

Declarative source of truth, deployed from the owner's PC with `./sync.sh`
(Terraform apply -> build all NixOS configs -> push to every VM -> git commit
"Generation: N"). You cannot deploy; you change the repo through pull requests,
and the owner merges and syncs.

- Repo: github.com/lsck0/homelab, clone at `/var/lib/hermes/workspace/homelab`:
  `git clone https://github.com/lsck0/homelab.git` once (git authenticates as the homelab GitHub App), then
  `git -C homelab fetch origin && git -C homelab checkout master && git -C homelab reset --hard origin/master`
  before every new change.
- Layout:
  - `src/instances.tf` guest inventory: id, `enabled` (true/"onDemand"/false), `kind` ("vm" or "lxc"; lxc may be `privileged` for nfs), `features`, `cooldown`, cores, memory, disk.
  - `src/lib.tf` VM plumbing, `src/main.tf` provider + variables.
  - `src/instances/<id>-<type>-<service>.nix` NixOS config per guest; it imports service fragments from `src/services/`.
  - `src/services/*.nix` one service each (lldap, kopia, forgejo-runner, paperless-ai, the *arr apps), so a service moves between guests by changing an import.
  - `src/modules/routes.nix` hostname -> VM/port table (Traefik + DNS).
  - `src/modules/*.nix` shared modules (base, traefik, on-demand, servarr, swarm, tokens, nas mounts); `apps.nix` is the app catalog, `catalog.nix` every route.
  - `src/modules/hermes/skills/` these skills.
  - `src/secrets.json` sops-encrypted secrets (never try to decrypt, never add plaintext secrets: the repo is public).
- Adding a service = a `src/services/<name>.nix` imported by an existing guest, or a new guest in instances.tf + `src/instances/<id>-<type>-<name>.nix`; plus a route in routes.nix.

## Opening a pull request

1. Start from fresh master (above), then `git checkout -b hermes/<topic>`
   (lowercase, e.g. `hermes/firefly-cooldown-1h`).
2. Make the smallest change that does the job, in the style of the file around it.
3. Check what you touched evaluates, e.g. for a VM config:
   `nix eval --raw ./src#nixosConfigurations.<name>.config.system.build.toplevel.drvPath`.
   Terraform files cannot be checked here; keep those edits minimal.
4. Commit with a conventional commit message: `type(scope): summary` in
   lowercase, a blank line, then why the change is needed. One commit per
   logical change.
5. `lab-pr` (inside the clone) pushes the branch, opens the pull request from
   your commit messages and prints its URL.
6. Tell the owner the URL and that it deploys with `./sync.sh` after merging.

To update an open pull request, commit on the same branch and run `lab-pr`
again. You cannot push to master or change `.github/workflows`: the app is not allowed
to, and only the owner merges.
