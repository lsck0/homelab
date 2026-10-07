---
name: ci-cd
description: Deploy apps to the apps swarm: the app catalog, the builder, the swarm, the registry, rollouts and rollback.
version: 3.1.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, CI, CD, Docker, Swarm]
    related_skills: [homelab-ops, forgejo, traefik-ingress]
---

# CI/CD: the apps swarm

An app is a folder `src/apps/<name>/` whose `app.nix` names a GitHub repo and a branch (every field, its type and
default: `src/modules/apps-catalog`, the shared route properties `src/modules/service.nix`). Everything else is
derived.

Flow on every push to that branch:

1. **Builder.** `app-builder` on vm-140 notices within 30 minutes (`git ls-remote`, run as user `appbuild`), at
   once when the app's CI posts to its `/redeploy` endpoint.
   With `watch` set it deploys only commits touching those paths. It builds the images in the lab and pushes
   them to `registry.lsck0.dev/<app>/<service>:<commit>` (user `builder`), `:latest` once deployed.
2. **Hand-off.** It hands the stack, pinned by digest, to the app's cluster: the apps swarm, whose manager is
   vm-140 itself, or an app's own guest (`placement`) over ssh restricted to one forced command,
   `swarm-apply <app>` (host key checked against `src/generated/known_hosts`).
3. **Manager.** The cluster's manager adds the homelab:
   - published ports, limits (`resources`, else 512 MiB / 1 cpu / 512 pids per task)
   - each service's own `env`, secrets from sops
   - encrypted overlay networks
   - stateful services pinned to the state worker vm-250, one task, stopped before replaced
   - a policy check: only allowed compose keys; refuses privileged settings, host paths, the docker socket,
     unpinned images, compose interpolation, undeclared volumes

   Then it deploys. New tasks start before old ones stop; a failed update rolls back and the deploy counts as
   failed. The stack is kept in `/var/lib/swarm-apply/<app>.yaml`.
4. **Converge.** Every sync that changes the catalog, the policy or an app secret re-renders every kept stack on
   vm-140 (`swarm-converge`) and removes the stacks of disabled or deleted apps. No app commit needed.
5. **Serving.** The workers vm-250, 251 and 252 (apps zone) serve the app. A route of zone `external` goes
   through the edge (vm-200), one of zone `internal` through vm-100; on both every protection is on (authelia,
   crowdsec, the waf, anubis where authelia is off, rate and body limits) unless the route says
   `off.<feature> = "<why>"`.

## Limits: one app never takes the lab down

- Each app holds `reservation` (default 1024 MiB, 0.5 cpu) of the workers: its tasks (memory of each times its
  replicas, 0.1 cpu each) must fit, or the deploy is refused naming the numbers; all reservations plus the
  largest once more (a rolling deploy) must fit the workers, or the sync fails naming the largest app.
- Each task: `resources.<service>` (default 512 MiB, 1 cpu, 512 processes); memory is reserved at its limit, so a
  task that outgrows it is killed inside itself, never a neighbour. Every capability is dropped; a stack lists
  what its entrypoint needs in `cap_add` (CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL, SETGID, SETUID,
  NET_BIND_SERVICE only).
- Each worker advertises what it holds beside its own services (HOMELAB_MEMORY_MIB, HOMELAB_CPU_MILLIS, see
  `docker node inspect`) and runs every container in `apps.slice`, capped at the same memory: a full worker
  leaves a task pending (its deploy fails and alerts) instead of starving dockerd.
- Each app's logs, spans, profiles and metrics have the same budget (`src/modules/limits` `tenant`); above
  it the app's own data is dropped or refused (429) and shows on its board, nobody else's.
- Each route admits 100 requests/s (burst 200, 200 at once) from all clients together, beside the per-client
  limits.
- `idle.stopAfter = "30m"`: the stack scales to 0 after that long without requests and the edge wakes it on the
  next one (holding the request); a deploy of a sleeping app keeps it asleep. State: `GET
  http://10.100.0.140:8095/state/<app>` from an ingress, metric `homelab_app_idle_stopped{app}`.

## Look

- Builder: `ssh 10.100.0.140 'systemctl status app-builder; journalctl -u app-builder -u "app-builder@*" -n 100'`.
  State per app: `/var/lib/app-builder/<app>.json` (`sha` live, `failure` with its retry time).
  Metrics: `homelab_app_deploy_ok{app}`, `homelab_app_deploy_failures{app}`,
  `homelab_app_builder_last_run_timestamp_seconds`.
- Manager: `ssh 10.100.0.140 'journalctl -t swarm-deploy -u swarm-converge -n 50'`; metric
  `homelab_swarm_deploy_ok{app}`.
- Swarm (manager only, workers hold no control):
  - `ssh 10.100.0.140 'docker stack ls; docker service ls; docker node ls'`
  - one app: `ssh 10.100.0.140 docker stack ps <app> --no-trunc`
- Logs of a service: Loki `{host=~"vm-25.", swarm_service="<app>_<service>"}`, or
  `ssh 10.100.0.140 docker service logs <app>_<service>`.

## Act

- **Rebuild and redeploy now:** on vm-140, `app-builder-redeploy <app>` (ignores the backoff). From the app's CI:
  `curl -fsS -X POST -H "Authorization: Bearer $DEPLOY_TOKEN" https://deploy.lsck0.dev/redeploy/<app>` (the
  app's token: sops secret `app-<app>-redeploy-token`; one per minute, coalesced while a build runs).
- **Restore a volume:** on vm-140 `docker service scale <app>_<service>=0`, then on the state worker
  `swarm-volume-restore <app> <volume> [<archive>]` (newest of `/var/backup/db/<app>-volume-<volume>/` by
  default), then scale back.
- **Apply the catalog again:** on vm-140, `systemctl restart swarm-converge`.
- **Roll back to an older build:** `ssh 10.100.0.140 docker service update --image registry.lsck0.dev/<app>/<service>@<digest> <app>_<service>`.
  The next push or converge replaces it; for a lasting rollback, revert the commit on the branch.
- **Scale a stateless service:** `docker service scale <app>_<service>=<n>` on vm-140. Stateful ones stay at 1.
- **Never** run `docker stack rm` or `docker volume rm` without the owner: volumes hold app data, and a disabled
  app's volumes stay on vm-250 until the owner removes them.

## Add an app (Nix change for the owner)

Copy `src/apps/_template/` to `src/apps/<name>/` and set `repo` and `branch`: the app answers at
`<name>.lsck0.dev` behind the edge and authelia, its port drawn from 20100 to 20999. A public app says
`routes.<name>.off.sso = "<why>"`; more routes, `idle`, `resources` and `placement` are optional. Repos without a
compose file need a root `Dockerfile` (service `web`, port 8000 unless the route says otherwise); a stack whose
services only name images needs `build` hints. Every named volume needs `volumes.<name>.backup`, its service in `stateful`.
Secrets go in `env.<service>` as `{{name}}` with a `secrets` generator; the owner then runs
`src/scripts/secrets-sync.sh --apply` and `./sync.sh`. A broken entry fails every host's build with a message
naming the field. Draft the entry; do not deploy it yourself.

## CI runners (vm-117)

- Forgejo (git.lsck0.dev): user `ci`, compile cache (sccache) and registry pushes as `ci`.
- GitHub: one runner per repo whose workflows use `runs-on: self-hosted`, user `gh-<repo>`, wiped before every
  job, dns and the internet only. Repos are listed in `src/instances/117-internal-github-runner/main.nix`.
- No job runs as root or reaches the nix daemon.

## Registry (vm-118, https://registry.lsck0.dev through vm-100)

- Writes (POST/PUT/PATCH, route registry-push): from vm-140 (the builder), vm-117 (forgejo ci) and the workstation, user `ci`
  (sops `registry-push-password`, a repo secret `REGISTRY_PASSWORD` for CI workflows) or `builder`. Nobody deletes through the ingress.
- Reads (GET/HEAD, route registry-api): the swarm nodes with user `puller` (each manager logs in and hands it to its workers),
  and the pushers with their own user. The methods never overlap, so vm-140 pulls as `puller` and pushes as `builder`.
- Catalog: `curl -s http://10.100.0.118:5000/v2/_catalog` (from vm-100 or the trusted hosts).
- Retention: `registry-prune` keeps `latest` and the 10 newest tags per repository, nightly.
- UI: https://registry-ui.lsck0.dev.
