---
name: forgejo
description: Forgejo repos, users, mirrors and Actions runs.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Forgejo, Git, CI]
    related_skills: [homelab-ops, ci-cd]
---

# Forgejo (vm-115, 10.100.0.115, https://git.lsck0.dev, git over SSH on port 2222)

API from here: `http://10.100.0.115/api/v1` (Swagger at `/api/swagger`), header
`Authorization: token $(lab-token forgejo-hermes)`. That token belongs to `hermes-bot`, an admin account made for
you: use it for everything. Never mint tokens on the owner's account (`luca`): nothing tracks or revokes them.

Admin CLI inside the container (podman): `ssh 10.100.0.115 podman exec -u git forgejo forgejo admin <cmd>`.

- Repos: `GET /repos/search?q=<name>`, create `POST /user/repos {"name":..., "private":true}`.
- Mirror a GitHub repo: `POST /repos/migrate {"clone_addr":"https://github.com/<o>/<r>","repo_name":"<r>","mirror":true,"repo_owner":"luca"}`.
  Every GitHub repo of the owner is mirrored daily anyway (`forgejo-mirror.service`, `journalctl -u forgejo-mirror`).
- Actions runs: `GET /repos/<owner>/<repo>/actions/tasks`; logs in the web UI.
- Users: logins are SSO through Authelia and create the account on first login. `forgejo admin user list`; local
  accounts are break-glass only (`forgejo admin user change-password --username <u> --password <p>` by hand).
- Setup units on vm-115 (all restart until they succeed): `forgejo-init`, `forgejo-oauth2-setup`,
  `forgejo-homepage-token`, `forgejo-hermes-token`, `forgejo-runner-token`; logs `journalctl -u <unit> -n 50`.
- Before every image upgrade `forgejo-upgrade-backup` keeps the database as `/var/lib/forgejo/gitea/gitea.db.before-<tag>`.

## Runner (vm-117, beside the GitHub runner)

- `ssh 10.100.0.117 'systemctl status forgejo-runner; journalctl -u forgejo-runner -n 50'`. It registers in its
  `ExecStartPre` with the token vm-115 exports (`lab-token forgejo-runner`); after a Forgejo reset,
  `systemctl restart forgejo-runner` on vm-117 registers it again.
- Labels and job isolation: the `ci-cd` skill.
