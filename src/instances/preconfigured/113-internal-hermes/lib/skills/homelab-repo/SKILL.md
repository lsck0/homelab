---
name: homelab-repo
description: Change the homelab config through pull requests on GitHub.
version: 1.4.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, NixOS, Terraform, GitOps]
    related_skills: [homelab-ops]
---

# The homelab repository

Declarative source of truth, deployed from the owner's PC with `./sync.nu`
(Terraform apply -> build all NixOS configs -> push to every VM -> git commit
"Generation: N"). You cannot deploy: the admin age key that sync.nu needs stays
on the owner's PC, and there is no deploy tool on vm-113. You change the repo
through pull requests, and the owner merges and syncs.

- Repo: github.com/lsck0/homelab, clone at `/var/lib/hermes/workspace/homelab`:
  `git clone https://github.com/lsck0/homelab.git` once (git authenticates as the homelab GitHub App), then
  `git -C homelab fetch origin && git -C homelab checkout master && git -C homelab reset --hard origin/master`
  before every new change.
- Layout (README.md "Layout" explains it once). Every file has one owner and lives in its folder:
  - `src/instances/core/<vmid>-<zone>-<service>/` one folder per guest the lab needs to function (router, ingresses, authelia,
    homepage, grafana, ntfy, nas, cache, registry, the deploy controller), `src/instances/preconfigured/` the same
    for every third-party service: `main.nix` its NixOS config, `instance.nix` what
    others need (vm shape incl. `power` on/off, `idle.stopAfter` for on-demand guests, `services` with their host,
    port and the features they opt into with `on`, grants, tokens, the guest's own `on` for egress and firewall
    openings, secrets), `lib/` everything only it uses (modules, scripts, templates, dashboards), `tests/` its
    checks, `skill.md` its Hermes skill.
  - `src/modules/` what two or more guests use: `<name>.nix`, or `<name>/` with `default.nix`, `lib/` and `tests/`.
    `lab/` collects every folder, `service.nix` and `instance-schema.nix` type them, `catalog.nix` every route;
    traefik, flows, network, on-demand, swarm derive from them.
  - `src/instances/custom/<name>/app.nix` one folder per app of the owner's own (repo, branch, routes, idle,
    placement); `src/instances/core/swarm.nix` the shared swarm (state worker, ports, worker shape; manager and builder are
    vm-107's roles).
  - `src/terraform/` terraform, which reads the guests from nix (`nix eval .#lab.terraform`).
  - `src/generated/` what scripts write: `site.json` (the machine and the house), `known_hosts`, `zones.json` (the
    zones: bridge, subnet, vmid range), the swarm workers' keys, terraform's state copy.
  - `src/secrets/` the shared secrets and the admins' recipients; `src/secrets/keys/` the authorized ssh keys.
  - `src/scripts/` the owner's workstation tools; `src/tests/` the test harness, the laws (`policy/`) and the
    tests of the whole lab. `src/tests/policy/placement.nix` fails a file in the wrong place.
  - `src/instances/preconfigured/113-internal-hermes/lib/skills/` the general skills.
  - Secrets are sops files you hold no key for, by design: never try to read them, never add a plaintext secret
    (the repo is public, the pre-commit hook refuses one). A new secret is a generator line in the owning
    instance's `secrets` (or `src/secrets/shared.nix`) plus `sops.secrets.<name>`; say in the pull request that
    the owner must run the secrets sync.
- Adding a guest = a new folder (copy `src/instances/preconfigured/_template/`); adding an app = a new
  `src/instances/custom/<name>/` with repo and branch. Nothing else is edited: ingresses, dns, the dashboard and
  terraform follow from the folder.

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
6. Tell the owner the URL and that it deploys with `./sync.nu` after merging.

To update an open pull request, commit on the same branch and run `lab-pr`
again. You cannot push to master or change `.github/workflows`: the app is not allowed
to, and only the owner merges.
