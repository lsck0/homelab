---
name: git-forgejo
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

# Forgejo (vm-115, https://git.lsck0.dev, SSH port 2222)

API from the LAN: `http://10.100.0.115/api/v1` (Swagger at /api/swagger).
Admin CLI inside the container: `ssh 10.100.0.115 podman exec -u git forgejo forgejo admin <cmd>`.

- Token for yourself: `podman exec -u git forgejo forgejo admin user generate-access-token --username luca --token-name hermes-<date> --scopes all`
  (store it in your memory only if the owner agrees; otherwise create per task and delete after).
- Repos: `GET /repos/search?q=<name>`, create `POST /user/repos {"name":..., "private":true}`.
- Mirror a GitHub repo: `POST /repos/migrate {"clone_addr":"https://github.com/<o>/<r>","repo_name":"<r>","mirror":true,"repo_owner":"luca"}`.
- Actions runs: `GET /repos/<owner>/<repo>/actions/tasks`; logs in the web UI.
- Users: `forgejo admin user list`, `forgejo admin user create --username <u> --email <e> --random-password`.
  Normal logins are SSO (Authelia); local accounts are break-glass.

## Runner (vm-116)

- `ssh 10.100.0.116 'podman ps; journalctl -u docker-forgejo-runner -n 50'`
  (runner runs under docker: `docker logs forgejo-runner`).
- Labels: `docker` (node:20), `ubuntu-latest` (catthehacker act image), `rust`.
- Re-register after a Forgejo reset: `systemctl restart forgejo-runner-register`.
- Build cache: sccache on vm-111 (`redis://sccache.lsck0.dev`).
