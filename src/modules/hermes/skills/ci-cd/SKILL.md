---
name: ci-cd
description: Deploy apps to the apps swarm: the app catalog, the builder, the swarm, the registry, rollouts and rollback.
version: 2.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, CI, CD, Docker, Swarm]
    related_skills: [homelab-ops, git-forgejo, traefik-ingress]
---

# CI/CD: the apps swarm

An app is a GitHub repo and a branch, listed in `src/modules/apps.nix`. Everything else is derived.

Flow on every push to that branch:

1. **Builder.** `app-builder` on vm-117 notices within a minute (`git ls-remote`, run as user `appbuild`).
   It builds the images in the lab and pushes them to `registry.lsck0.dev/<app>/<service>:<commit>`.
2. **Hand-off.** It sends the stack, pinned by digest, to the swarm manager vm-140 over ssh. The key is
   restricted to one forced command, `swarm-apply <app>`.
3. **Manager.** vm-140 adds the homelab:
   - published ports
   - secrets from sops
   - encrypted overlay networks
   - stateful services pinned to the state worker
   - a policy check that refuses privileged settings, host paths, the docker socket and unpinned images

   Then it deploys. New tasks start before old ones stop, and a failed healthcheck rolls back.
4. **Serving.** The workers vm-150, 151 and 152 (apps zone, 10.150.0.0/24) serve the app. Public paths go
   through the edge (vm-200: crowdsec, waf, anubis, rate limits, `<host>.lsck0.dev`). `internal` hosts go
   through vm-100 behind authelia.

## Look

- Builder: `ssh 10.100.0.117 'systemctl status app-builder; journalctl -u app-builder -n 100'`.
  Last good commit per app: `/var/lib/app-builder/<app>.sha`. Metrics: `homelab_app_deploy_ok{app}`.
- Swarm (manager only, workers hold no control):
  - `ssh 10.100.0.140 'docker stack ls; docker service ls; docker node ls'`
  - one app: `ssh 10.100.0.140 docker stack ps <app> --no-trunc`
- Logs of a service: Loki `{host=~"vm-15.", swarm_service="<app>_<service>"}`, or
  `ssh 10.100.0.140 docker service logs <app>_<service>`.

## Act

- **Redeploy the current commit:** on vm-117, remove `/var/lib/app-builder/<app>.sha`, then
  `systemctl start app-builder`.
- **Roll back to an older build:** `ssh 10.100.0.140 docker service update --image registry.lsck0.dev/<app>/<service>@<digest> <app>_<service>`.
  The next push replaces it; for a lasting rollback, revert the commit on the branch.
- **Scale a stateless service:** `docker service scale <app>_<service>=<n>` on vm-140. Stateful ones stay at 1.
- **Never** run `docker stack rm` or `docker volume rm` without the owner: volumes hold app data.

## Add an app (Nix change for the owner)

Add an entry to `src/modules/apps.nix` with `repo`, `branch` and `paths` (unique published `port`s from 20100
up), plus `enable = true`. Repos without a compose file need a root `Dockerfile`; a stack whose services only
name images needs `build` hints. Secrets go in `env` as `{{name}}` with a `secrets` generator; the owner then
runs `src/scripts/secrets-sync.sh --apply` and `./sync.sh`. Draft the entry; do not deploy it yourself.

## Registry (vm-118, https://registry.lsck0.dev through vm-100)

- Pulls: GET/HEAD from the swarm nodes only. Pushes: from vm-117 and the workstation, with user `ci` and the
  sops secret `registry-push-password` (a repo secret `REGISTRY_PASSWORD` for CI workflows).
- Catalog: `curl -s http://10.100.0.118:5000/v2/_catalog` (from vm-100 or the trusted hosts).
- Retention: `registry-prune` keeps `latest` and the 10 newest tags per repository, nightly.
- UI: https://registry-ui.lsck0.dev.
