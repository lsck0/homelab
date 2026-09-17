---
name: homelab-repo
description: How config is deployed; draft changes for the owner.
version: 1.0.0
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
"Generation: N"). You cannot run it; you can read the repo and prepare changes.

- Repo: github.com/lsck0/homelab (clone read-only into your workspace with `git clone`
  if you need to read it; `git -C homelab pull` to refresh).
- Layout:
  - `src/instances.tf` VM inventory: id, `enabled` (true/"onDemand"/false), `cooldown`, cores, memory, disk.
  - `src/lib.tf` VM plumbing, `src/main.tf` provider + variables.
  - `src/instances/<id>-<type>-<service>.nix` NixOS config per VM.
  - `src/modules/routes.nix` hostname -> VM/port table (Traefik + DNS).
  - `src/modules/*.nix` shared modules (base, traefik, on-demand, servarr, docker-stack/swarm, nas mounts).
  - `src/modules/hermes/skills/` these skills.
  - `src/secrets.json` sops-encrypted secrets (never try to decrypt).
- Adding a service = VM entry in instances.tf + `src/instances/<name>.nix` + route in routes.nix.

When a fix must be permanent, reply with the exact file and a minimal diff for
the owner to apply, then say they need to run `./sync.sh`.
