---
name: ci-cd
description: Deploy apps: registry, Swarm stacks, rollouts, rollback.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, CI, CD, Docker, Swarm]
    related_skills: [homelab-ops, git-forgejo]
---

# CI/CD

Flow: push to Forgejo or GitHub -> CI builds an image -> pushes to a registry ->
vm-209 (10.200.0.209, Docker Swarm) polls every minute and rolls out a new
digest with start-first updates (no downtime; failed healthcheck = rollback).

- Forgejo -> `registry.lsck0.dev/<app>:latest` (internal registry vm-118).
  Template: `example/.forgejo/workflows/hello.yml` in the homelab repo.
- GitHub -> `ghcr.io/<owner>/<app>:latest`. Template: `example/.github/workflows/hello.yml`.
- Any registry works; private images need credentials in `homelab.swarm.registries` (Nix).

Note: the `hello-gh` stack has no image yet. `example/.github/workflows/hello.yml`
is a template, not an active workflow in this repo, so nothing has ever pushed
`ghcr.io/lsck0/hello` and the swarm task stays `Rejected: No such image`. That
route is marked `monitor = false` in routes.nix so it is not a standing alert.

## Runners

- **Forgejo** vm-116: one runner for `git.lsck0.dev`.
- **GitHub** vm-117 (10.100.0.117): ephemeral runners, one systemd unit per
  replica, registered straight to a repo. A job gets a fresh runner and a wiped
  state directory, then the runner de-registers itself.
  - which repos: the `repos` set at the top of
    `src/instances/116-internal-github-runner.nix`, `<owner>/<repo> = <parallel
    jobs>`. Adding or removing one is that line plus `./sync.sh` - draft the
    snippet for the owner, this needs a deploy.
  - target them with `runs-on: [self-hosted, nixos]`.
  - state: `ssh 10.100.0.117 'systemctl list-units "github-runner-*"'`,
    logs `journalctl -u github-runner-<owner>-<repo>-<n>`.
  - registration uses the `github-runner-token` PAT; a unit stuck in
    activating usually means that token lost `Administration: read and write`
    on the repo.

## On vm-209

- Stacks/services: `ssh 10.200.0.209 'docker stack ls; docker service ls'`
- Rollout state: `docker service ps <stack>_web --no-trunc | head`
- Logs: `docker service logs --tail 100 <stack>_web`
- Force a pull + rollout now: `systemctl start swarm-update` (journal: `journalctl -u swarm-update -n 30`)
- Roll back to the previous version: `docker service rollback <stack>_web`
- Pin a specific build: `docker service update --image registry.lsck0.dev/<app>:<sha> <stack>_web`
  (the next poll moves it back to `latest`; tell the owner to push a revert instead for a lasting pin).

## Adding a new app

Needs Nix changes the owner deploys: a stack in `src/instances/209-external-hello.nix`
(image, published port, healthcheck) and a route in `src/modules/routes.nix`
(`external.<app> = { host; vmid = 209; port; }`). Draft both snippets for the owner.

## Registry (vm-118)

- Catalog: `curl -s http://10.100.0.118:5000/v2/_catalog`, tags `curl -s http://10.100.0.118:5000/v2/<app>/tags/list`.
- Delete a tag: get digest with `curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" http://10.100.0.118:5000/v2/<app>/manifests/<tag>`, then `curl -X DELETE http://10.100.0.118:5000/v2/<app>/manifests/<digest>`;
  reclaim space: `ssh 10.100.0.118 podman exec registry bin/registry garbage-collect /etc/docker/registry/config.yml`.
- UI: https://registry-ui.lsck0.dev.
