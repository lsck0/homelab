# Handoff: homelab, state after Generation 448 (2026-10-07)

This file is everything a fresh agent (for example a cloud agent working from the GitHub repo) needs to finish the
open work. It is self-contained: the architecture, every user decision, the rules, the full review report and the
ordered task list are below. Paths are relative to the repo root (`homelab/`), the flake lives in `src/`.

## 0. What a cloud agent can and cannot do

- **Can:** read and edit the repo, evaluate the flake (`nix eval path:./src#...`), build checks
  (`nix build path:./src#checks.x86_64-linux.<name> -L --no-link --max-jobs 1`, VM tests one at a time), run
  shellcheck, `terraform -chdir=src/terraform init -backend=false && terraform validate && terraform fmt -check`.
- **Cannot:** reach the lab (it is on the owner's LAN: 10.100.0.0/24 internal, 10.200.0.0/24 dmz, 10.250.0.0/24
  apps, Proxmox 192.168.178.200), decrypt secrets (sops files are encrypted to the owner's admin keys and per-host
  keys), deploy (`./sync.sh` runs on the owner's workstation, needs the YubiKey-backed ssh agent and the admin age
  key), or push to `master` without the owner (sync.sh commits each deployed generation itself).
- **So:** do the code work, prove it with checks, open a pull request (or push a branch) and list the exact steps the
  owner runs (deploy, live checks, Proxmox, GitHub, secrets). Never fabricate live results.

## 1. Where things stand

- **Live:** Generation 448 (commit `0d52be3` on `master`). The restructured lab runs: one folder per instance
  (`src/instances/<vmid>-<zone>-<name>/`), a collector (`src/modules/lab`), per-folder sops secrets, swarm workers
  vm-250..252 (joined, the `hello` app serves), deploy controller on vm-140, apps zone 10.250.0.0/24, host
  firewalls restored on all guests after a migration glitch.
- **Arch mirror:** fixed and complete (the owner resolved the last missing package). Builder: vm-119
  (`src/instances/119-internal-archbuild`), mirror: vm-210 (`src/instances/210-external-mirror`), status at
  `https://mirror.lsck0.dev/status.json`, logs at `https://mirror.lsck0.dev/logs/<name>.log`. The builder reads
  arch-dotfiles' `configs/*/packages.txt` plus every platform's `EXTRA_PACKAGES`, uses local recipes from
  `mirror/pkgbuilds/` first, drops a split package base's own siblings from its build deps, bounds build parallelism
  by memory through the build container's cpuset (one cpu per 2 GiB), runs with `OOMPolicy=continue`, and holds a
  night back rather than lose a served package.
- **Live hot fix not yet in a generation:** vm-100 (internal ingress) had thrashed to a halt with a 512 MiB balloon
  floor; the owner's session raised it live (`qm set 100 --balloon 1024`) and wrote `balloonMiB = 1024` into
  `src/instances/100-internal-traefik/instance.nix`. That edit must survive into the next deploy.
- **Review-2 fix round:** in progress on branch `review2-fixes`; the checkpoint below (section 1a) is what the branch
  holds now, what is verified, what is open, and what the owner must do before deploying it.

## 1a. Checkpoint of the review-2 fix round (2026-10-07, branch `review2-fixes`)

**Recommendation: do not deploy this checkpoint yet.** It is a consistent, evaluating base, but most review-2
findings are still open and policy-eval fails on the memory budget (#1). Deploy when the round is finished; the
steps below are written so that a local agent with lab access can do them then (or now, if the owner decides to).

### What holds now (verified in the cloud, no lab access)
- Every nixosConfiguration evaluates (32). Every eval-only check builds, except `policy-eval` (below).
- `shellcheck` (now including every shell body embedded in nix) and `secrets-check` pass (git flake).
- `terraform init -backend=false && terraform validate && terraform fmt -check` pass (terraform 1.14.0, providers
  from a filesystem mirror; the lock file is unchanged).
- VM test `harness-smoke` passes. Every other VM test evaluates; none of them has been run on this branch yet.
- `policy-eval` reports: the host memory budget (#1: floors 41984 MiB vs 32022 MiB on the node, open), and secrets
  files that do not hold exactly their declared names (clears with the secrets steps below).

### Finding status at this checkpoint
| status | findings |
|---|---|
| fixed and verified by checks | 28 (pinned hermes-agent reads `ANTHROPIC_TOKEN` as the OAuth token and scrubs it from every command; `CLAUDE_CODE_OAUTH_TOKEN` was not scrubbed, so the leak was real: switched), 42, 43, 47, 48, 49, 81, 85 |
| rejected by the owner | 3; 16 (Hermes keeps root ssh everywhere; only its key comment was corrected to vm-114, and Hermes now checks host keys strictly against `src/generated/known_hosts`) |
| partly done (draft finished to evaluate, not yet reviewed against the finding) | 1 (law exists, shapes do not fit yet), 5, 14, 15, 45, 46, 50, 53 |
| open (the draft may hold partial work in these areas; unreviewed) | every other finding |

Main changes beyond the draft: the typed app catalog lives in `modules/lab` once (`lab.appsCatalog`, `lab.catalog`,
`lab.withApps f` for fixture apps; `homelab.appsCatalog` is gone); swarm workers derive from the enabled apps'
reservations (`modules/limits` `workerCountOf`); hosts and test guests get their instance record as `instance`; NAS
shares are declared in instance.nix and checked by a policy law (`tests/policy/guests.nix`); every policy law has a
positive control (`tests/policy-controls.nix`); the Hermes "observer" account of the draft is reverted (owner
decision), keeping its strict known-hosts, `ANTHROPIC_TOKEN` and the declared skills tree; sync.sh's
`terraform init` passes `-reconfigure` (the draft moved the state path to `~/.local/state/homelab/terraform`, and
init on a workstation with an existing `.terraform` failed with "Backend configuration changed"); `DOTFILES_SECRETS`
works again.

### Owner / local agent steps, in order (only when deploying this branch)
1. **Secrets: restore the values that moved from runtime tokens to sops** (guardsData: `secrets-sync` stops until each
   is set; never generate new ones, the apps hold the live values). On the workstation, in the repo, for each line
   (`<token dir>`: where the live token is, `<file>`: where the value goes):
   ```
   # name                 token dir      file
   # radarr-key           vm-130         src/secrets/shared.sops.json
   # sonarr-key           vm-130         src/secrets/shared.sops.json
   # lidarr-key           vm-130         src/secrets/shared.sops.json
   # prowlarr-key         vm-130         src/secrets/shared.sops.json
   # jellyfin-admin-pass  vm-134         src/secrets/shared.sops.json
   # janitorr-pass        vm-134         src/instances/134-internal-jellyfin/secrets.sops.json
   # navidrome-pass       vm-136         src/instances/136-internal-navidrome/secrets.sops.json
   ssh root@10.100.0.109 cat /srv/nas/data/tokens/<token dir>/<name>.token | jq -Rc . \
     | SOPS_AGE_KEY_FILE=secrets/age.txt sops set --value-stdin <file> '["<name>"]'
   ```
   (`--value-stdin` keeps the value off argv; `jq -Rc .` makes it the JSON string sops expects.) The two
   `secrets.sops.json` files above are new and hold empty placeholders; the shared values live in
   `src/secrets/shared.sops.json`.
2. `src/scripts/secrets-sync.sh` (dry run), read it, then `--apply`: it moves `registry-push-password` from vm-100's
   file to the shared file (value kept), generates the new `qbittorrent-pass` (vm-112 sets the web UI password from it at every start) and the
   readers' shared copies, drops `proxmox-ca` (#53), and rewrites `.sops.yaml` (rules for 134/136 added, workers 251/252
   removed). Run `--prune` only after reading what it would delete.
3. **Terraform plan check** (sync.sh prints it; nothing is applied without reading it): expected
   - destroy vm-251 and vm-252 (stateless swarm workers; the derived worker count is 1 for the one enabled app);
   - vm-105 disk 16 -> 80 GiB (grow, in place): prometheus, loki and pyroscope move to local disk through
     `homelab.localState`, whose first seed copies the NAS copy (keep the share; the first start takes a while);
   - the Proxmox firewall turns on with input policy DROP (#2, draft): host rules admit ssh from the house lan,
     8006 only from the workstation (`site.json lan.workstation`) and the router, node exporter and ping. **Before
     applying, check `src/generated/site.json` `lan.workstation` (192.168.178.138) is the workstation's real address**, and keep a
     console (or `pve-firewall stop` over ssh) ready: a wrong address locks the API and web UI out;
   - no `must be replaced` on any existing guest. The draft removed the `moved {}` block of the gpu mapping
     (`gpu` -> `gpu[0]`): fine once a deploy applied it; if the plan wants to destroy `gpu` or create `gpu[0]`, stop.
4. Deploy: `cd ~/projects/homelab && DOTFILES_SECRETS=~/projects/arch-dotfiles/configs/secrets ./sync.sh`
   (the terraform state moves once to `~/.local/state/homelab/terraform`, a copy stays beside it as `.moved-from-src`).
5. Live checks: section 3 below, plus `ssh root@10.100.0.140 docker node ls` (vm-250 Ready, 251/252 gone),
   `ssh root@10.100.0.105 systemctl status prometheus-seed loki-seed` (seeded, not diverged), Hermes answers on
   Telegram and `ssh root@<guest>` works from vm-114 (strict host keys), the *arr apps, Jellyfin, Janitorr, Navidrome
   and the homepage widgets work with the restored keys.

### Still to do in the round (cloud side)
- Groups collector, telemetry and host-tooling were in progress at this checkpoint; network-edge, swarm-apps,
  data-secrets and instances not started (plan: section 2).
- New owner requirement for every group: everything that depends on a third-party service (AUR, GitHub, Cloudflare,
  Let's Encrypt, Proton, Telegram, Anthropic, image registries, crowdsec hub, upstream DNS, feeds) survives its
  outage: bounded timeouts, retry with backoff, keep the last good state, no bogus failures, self-recovery, one
  distinct "<service> unavailable" alert. First known case: archbuild (vm-119) recorded 67 failures during an AUR
  outage on 2026-10-07; it must retry, then skip the night as "AUR unavailable".
- Run every touched VM test (one at a time), the final 7-dimension review, then update this section.

## 2. The task: fix every confirmed review-2 finding except #3

The full report is Appendix D (122 confirmed findings: 1 critical, 12 high, 42 medium, 39 low; numbered entries
1 to 94 after merging duplicates). The owner rejected #3: the internal zone keeps reaching everything. Everything
else is to be fixed at the root cause.

The interrupted round planned seven groups with disjoint files (a file belongs to exactly one group, so groups can
be worked in parallel). Reuse it:

| group | findings | theme |
|---|---|---|
| collector | 1, 16, 43, 45, 47, 48, 49, 50, 82, 88, 89, 90 | host memory budget law, schema/collector primitives, facts stated once |
| network-edge | 5, 23, 24, 38, 39, 44, 56, 57, 59, 62, 65, 79, 80, 91 | grants/flows, ingresses, client identity, sso lockout, tcp/udp exposure |
| telemetry | 7, 11, 20, 21, 22, 25, 46, 58, 61, 66, 76, 77, 92 | loki/tempo/pyroscope tenants, alerting path, stale metrics, logs privacy |
| swarm-apps | 13, 30, 32, 35, 37, 40, 51, 55, 60, 72, 73, 74, 75 | swarm, controller, render, image keys, volume restore, app coupling |
| data-secrets | 8, 14, 15, 17, 18, 19, 34, 36, 53, 54, 67, 69, 70, 86, 87 | localState restore, dbs off NFS, secrets guard, kopia verify, tokens channel |
| instances | 10, 12, 26, 27, 28, 29, 31, 71 | pingvin registration, runner crash loop, pinned plugins/images, hermes skills |
| host-tooling | 2, 4, 6, 9, 33, 41, 42, 52, 63, 64, 68, 78, 81, 83, 84, 85, 93, 94 | proxmox firewall, lldap realm 2fa/ldaps, terraform tls, pve cert, sync.sh robustness |

Order of work:
1. Critical and high first: #1 (memory budget law plus resizing), #2, #4 to #12. Then the primitives that make most
   mediums disappear (one grant primitive, one key/CA/trust primitive, state only through localState or volume
   backups, the memory budget). Then the rest.
2. For every fix: add or extend a check (table test, policy law under `src/tests/policy/`, or VM test). The flake
   discovers checks in `src/tests/*.nix`, `src/instances/*/tests/*.nix` and `src/modules/*/tests/*.nix`.
3. Before handing back: every nixosConfiguration evaluates, terraform validate and fmt pass, shellcheck passes,
   `policy-eval` passes (except the one rule that needs the owner's secrets-sync if a new secret was declared:
   say so), every eval-only check passes, the touched VM tests pass. Report per finding: fixed / partly / needs-owner.

Watch out for:
- **#28 (Hermes `CLAUDE_CODE_OAUTH_TOKEN` unsupported):** probably a wrong finding. Hermes 0.21.3
  (`agent/anthropic_credentials.py`) reads `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_TOKEN` as an OAuth credential;
  the owner chose the OAuth token deliberately. Verify in the pinned hermes-agent source before touching it.
- **#1 memory:** the Proxmox host has 32 GiB; balloon floors summed to about 43 GiB. A policy law must fail
  evaluation when floors + LXC limits + ZFS ARC max + a named reserve exceed host RAM, and the shapes must be made
  to fit (swarm workers are 2.5 GiB unballooned for one small app; vm-140 has 4 GiB for builds).
- **#2 Proxmox firewall:** turning it on is a host-level change; write the activation steps (keep ssh and 8006
  reachable from the workstation and the ingresses) and make the default safe; the owner applies it.
- **Data safety:** never change data paths, share/volume/database names, file-owning uids, unregenerable secret
  names, backup repository settings or terraform disk definitions without a data-preserving migration. New secrets
  need a declaration (instance.nix `secrets` or `src/secrets/shared.nix`); the owner generates values.

## 3. What the owner runs after the code is done

```
cd ~/projects/homelab && DOTFILES_SECRETS=~/projects/arch-dotfiles/configs/secrets ./sync.sh
```
(`DOTFILES_SECRETS` only until the local dotfiles checkout is on the modules layout.) If the change touched
`src/terraform` or any instance's `vm` shape, read the terraform plan first: no `must be replaced` on an existing
guest. Live checks after the deploy: `systemctl --failed` empty on every guest; `iptables -S nixos-fw` present;
`https://auth.lsck0.dev`, `https://hello.lsck0.dev`, `https://mirror.lsck0.dev/x86_64/lsck0.db` answer;
`ssh root@10.100.0.140 docker node ls` shows vm-250..252 Ready; on-demand wake works; ntfy desktop
notifications and the Quickshell homelab widget work (both read `src/generated/lab.json`).

## 4. Known live problems until the fix round is deployed

- On-demand wake and reap fail silently: the Proxmox certificate lacks 192.168.178.200 (#9).
- `github-runner-nyangine` on vm-117 crash-loops (#12); the "app deploy failed" alert pages permanently from a stale
  textfile on vm-117 (#11).
- Pingvin Share (vm-207) allows open registration (#10).
- SearXNG answered 429 to a single request (rate limit), not investigated.

## 5. Owner steps outside the repo (list them in your hand-back; you cannot do them)

1. Move `~/projects/arch-dotfiles` to the modules layout (`git branch backup-pre-modules 4abb0d3 && git reset --hard
   origin/master && git submodule update --init secrets`, unlock `secrets/`); then `DOTFILES_SECRETS` is unneeded.
2. Rotate the Claude OAuth token (`claude setup-token` into `secrets/claude-oauth-token` of the secrets submodule)
   and the ntfy desktop token (`sops unset src/instances/203-external-ntfy/secrets.sops.json
   '["ntfy-desktop-token"]'`, `secrets-sync.sh --apply`, commit the secrets submodule, sync): both appeared in
   session output.
3. Rotate the lldap admin password; revoke Hermes' old Proxmox API token.
4. GitHub: remove offline runners (homelab x2, arch-dotfiles, webapp-template); on lsck0/nyangine require approval
   for fork PR workflows; replace the runner PAT with a fine-grained token for nyangine only; store each app's
   `app-<name>-redeploy-token` as a CI secret of its repo.
5. Home Assistant: enter current gas and water readings once (gas about 3278, water about 276); delete
   `sensor.gaszahlerstand` and `sensor.wasserzahlerstand`; point HA's Energy dashboard at the new sensors.
6. TRMNL: update every plugin URL from `ssh root@10.100.0.104 cat /var/lib/terminal/feeds.txt`; calendar
   subscribers use the new `cal.lsck0.dev` URL.
7. Jellyfin users need the `app-jellyfin` group; apps pair via Quick Connect.
8. Fronius: find the unmetered generator with `fronius_site_info{meter_location}` on the Energie board.
9. Cleanup after confirmation: NAS shares `traefik-acme-internal`, `traefik-acme-external`, `crowdsec-internal`,
   `crowdsec-external`; the `vmbr150` stanza on the Proxmox host; the empty `wake-internal`/`wake-external` pools;
   `/var/lib/archbuild/cache/cargo-target` on vm-119.
10. Admin key rotation per README "Rotating the admin key", when convenient.

## 6. Open decisions (the owner's; do not decide them)

- Global time zone: hosts run UTC; switching to Europe/Berlin shifts every timer by 1 to 2 hours.
- `sync.sh` Proxmox hookscript block: buggy, probably never ran; fixing it installs an LVM filter on the hypervisor
  and restarts pvestatd.
- Six LXCs pending VM migration: 103, 104, 128, 136, 203, 204 (each: back up, recreate, restore).
- Visitor lists in the Quickshell widget: Loki is deliberately unreachable from the LAN; a read-only path would go
  through Grafana's datasource proxy.
- vm-140 memory: 4 GiB for builds, 3 GiB if the host stays tight.

## 7. Rules for any agent working on this repo

- Follow the owner's style skills if available (l-style, l-style-architecture, l-style-testing); in short: find the
  primitives first, no duplication (a fact is stated once and derived everywhere), every literal a named constant
  defined once, one-line why-comments only (no comment stacks, no what-comments; longer rationale goes into a module
  header block), plain readable code (lines go down by removing duplication, never by packing), ASCII only, zero
  lint findings, no hacks (`|| true`, sleeps, magic numbers, disabled checks), declarative over imperative.
- Placement: a file used by exactly one instance lives in that instance's folder (`main.nix`, `instance.nix`,
  `lib/`, `tests/`, `skill.md`); shared things are modules (`src/modules/<name>.nix` or
  `<name>/{default.nix,lib/,tests/}`); src/ top level holds only `flake.nix`, `flake.lock` and the folders `apps
  generated instances lab modules scripts secrets terraform tests`; `src/tests/policy/placement.nix` enforces it.
- Public repo (github.com/lsck0/homelab): nothing secret in plaintext; `src/scripts/secrets-check.sh` guards
  commits. Generated files (`src/generated/*`, `.sops.yaml`) come from scripts or the flake, never by hand.
- Kept owner decisions: swarm manager vm-140 stays internal; workers 250+ in the apps zone; repo stacks always run
  under docker swarm (shared cluster or a single-node guest); images built on vm-140 and parked in
  registry.lsck0.dev; homelab-only changes (never edit webapp-template or other repos); Hermes has root ssh
  everywhere; CI jobs never get root; per-host age keys; the internal zone reaches everything; every protection and
  telemetry feature defaults on, opt-outs carry a `why`.

The appendices hold the full detail: A architecture and every user requirement, B cleanup and data-safety rules,
C test harness API, D the review-2 report.

---

# Appendix A: architecture and user requirements (RESTRUCTURE.md)

## Restructure: everything an instance needs lives in its folder

User's words: "if I make a new instance, I need to edit several different files across everything. I want changes to
one instance focused into instances/<number-name>. ... the secrets, the things in modules, the things in scripts
should all be very, very close to the actual instance that needs it, if it's only needed by one. If it's needed by
multiple, then we leave it outside." Same treatment for swarm apps (apps/<name>/).

## Placement rule (enforced by a policy law, see below)
- Used by exactly one instance (a module, a services/*.nix, a script, a template, a secret, a Hermes skill about that
  service, a test about that host): it lives in that instance's folder.
- Used by two or more instances: it stays outside (src/modules, src/scripts, src/secrets.sops.json, ...).
- Facts other hosts need about an instance (its vm shape, routes, homepage card, oidc client, who may reach which of
  its ports, tokens it produces, egress class) are declared in that instance's instance.nix and collected centrally;
  consumers (ingresses, authelia, lldap, homepage, prober, router, terraform) never hard-code another instance.

## Layout (approved by the user)
src/instances/134-internal-jellyfin/
  main.nix                  NixOS config of the host (today's instances/134-internal-jellyfin.nix)
  instance.nix              pure data other hosts read, nothing else:
                              vm = { memory; cores; kind; power; bootPhase; privileged; features; disks; ... }
                              routes = { jellyfin = { host; port; auth; health; waf; ... }; }
                              homepage = { group; name; icon; desc; widget; }   (cards may reference own routes)
                              oidc = { ... }                                     (authelia client)
                              grants / flows targeting this host (who may reach which port)
                              tokens = { produces = [ ... ]; }
                              egress = "vpn" | "direct" | ...
                              secrets = { <name> = "<generator>"; }              (only-here secrets' generators)
  secrets.sops.json         secrets only this host reads (admin recipients + this host's key); edited with sops
  secrets.shared.sops.json  GENERATED by sync: the shared secrets this host reads (admin + host key); never edited
  age.pub                   host age recipient (public)
  age.sops                  host age private key, encrypted to the admin recipients only
  lib/                      only-here modules, scripts, templates (e.g. jellyfin-setup.sh)
  skill.md                  Hermes skill about this service (Hermes collects every instance's skill.md)
  tests/                    tests about this host only (flake discovers them like src/tests/*.nix)
src/apps/<name>/            same idea for swarm apps: app.nix (today's apps.nix entry), secrets.sops.json, lib/
Gone (generated from the folders or moved): src/instances.tf, src/modules/routes.nix, src/inventory.json,
src/host-keys.json, src/host-secrets/, src/modules/apps.nix (one big file), single-use services/*.nix and scripts.
Stays outside: src/modules/* used by 2+ hosts (base, network, traefik, nas, swarm, tokens, ...), main.tf/lib.tf
(terraform machinery), zones.json, site.json, admin-recipients.txt, src/secrets.sops.json (only secrets 2+ hosts
read, plus infra secrets), multi-host scripts, general Hermes skills (homelab-ops, media, ...) in Hermes' own folder.

## Mechanics (decided)
- One collector (e.g. src/lab/default.nix or src/modules/lab.nix): reads zones.json, site.json, every
  instances/*/instance.nix and apps/*/app.nix; computes inventory (ip/prefix/gateway from zones + vmid, as terraform
  does today with cidrhost) and the catalog (routes, homepage, oidc, grants, tokens, egress, vm specs). Exposed as a
  flake output (`lab`) and as module args for every host and test. Name each host from its folder name; the vmid and
  zone come from the folder name (`<vmid>-<zone>-<name>`), asserted against data.
- Terraform reads the same data from Nix (single direction, no generated file to go stale): e.g.
  `data "external"` running `nix eval --json` of the flake's terraform view (one JSON string field, jsondecode'd).
  Resource keys (vmid strings) must stay identical: no state moves, `terraform plan` must show no change.
- Secrets: per-instance sops files with .sops.yaml creation rules generated per folder; secrets-sync/secrets-hosts/
  secrets-check/sync.sh adapted; a one-time migration (needs the admin key, so it is a script the USER runs, wired
  into sync.sh idempotently or as an explicit step) splits src/secrets.json into the instance files +
  src/secrets.sops.json and host-keys.json into age.sops/age.pub. Agents never decrypt real secrets; the migration
  is tested with throwaway keys in the sandbox.
- Policy law (src/tests/policy/placement.nix): a module/script/secret/skill used by exactly one instance must live in
  its folder; a shared one must not live in an instance folder; every instance folder has main.nix + instance.nix.
- Refactor proof: for every host, toplevel drvPath before == after, except where a change is intended and explained.
- Docs: README "Adding an instance" = create one folder (copy a template folder), nothing else; the whole tree
  explained in one place.

## Addendum (user, later the same day)
Numbering = zones, vmid range = subnet's third digit group:
- 0: WireGuard clients, 10.0.0.0/24 (no VMs; already so in modules/net.nix).
- 100-199: internal zone, 10.100.0.0/24.
- 200-249: external zone (dmz), 10.200.0.0/24. The external DHCP pool (.211-.254 today) must not overlap 200-249.
- 250 and up: swarm nodes, apps zone moves to 10.250.0.0/24 (vmbr250), the nodes are vm-250, vm-251, vm-252.
  They are externally reachable, so they are not in the 1xx range. The swarm overlay pool (10.250.0.0/16 in
  modules/swarm.nix today) must move to a range that overlaps no zone.
- Swarm nodes are created programmatically: one data entry (count and per-node shape) generates them; no
  hand-written instance folder per node (the swarm node config is the shared module). The manager vm-140 stays an
  internal instance (user decision).
- Recreating 150-152 as 250-252 destroys and creates VMs: fine now (only `hello`, stateless, was deployed and the
  workers never joined). Say it in the user steps (bridge vmbr250 on Proxmox via pve-install, old vmbr150 removed).

Per-app isolation (phase after the restructure):
- Every app gets a generated Grafana dashboard (resources from cadvisor, traffic/errors/latency from the edge,
  logs, traces, profiles, deploy status), not only apps exporting the template's server metrics: nothing lost
  compared to the template's own monitoring stack.
- Prometheus, Pyroscope (and Loki/Tempo) per app isolated: per-app scrape jobs with sample/label limits, per-app
  tenants or label-scoped limits for profiles/logs/traces, so a new or noisy app never affects other apps or the
  monitoring stack. Deploying a new app must not require caring about other apps.
- Resource sharing: per-app CPU/memory limits and reservations, swarm placement spreading, node-level caps so the
  swarm VMs cannot starve the lab (Proxmox cpuunits/cpulimit, disk IO and NIC rate limits for swarm nodes), edge
  rate/inflight limits per app, log rate limits. One loaded app must not take the homelab down; a test proves it
  (load one app, the others and the lab keep answering).

Cleanup (last phase, whole repo): remove comment spam (comments only where a why is not obvious, one line, per
l-style), hacks and workarounds; best practices from the user's l-style skills everywhere. .hypothesis/ caches and
other test artifacts never inside src/ (gitignored or redirected).

## Addendum 2: one service schema for everything, every feature default on (user)
User: "the same config should also allow for things like setting the URL, enabling/disabling metrics, traces,
Grafana stuff, Authelia, Anubis, ModSecurity, etc. This new system could then also be used on the internal and
externally deployed things. Just have everything default on."
- ONE typed schema (a shared module, e.g. src/modules/service.nix) describes an exposed service, used identically by
  instance.nix (NixOS instances, internal and external) and apps/<name>/app.nix (swarm apps). Only the backend
  differs: a NixOS instance names its port on its own vm; a swarm app names a stack service and target port, and is
  built from its repo's Dockerfiles / compose file as today.
- Per exposure (route): host (<host>.<domain>, default the service name), path prefix, zone (default the
  instance's zone; apps: external), port, health path, and feature toggles, ALL DEFAULT ON (opt-out explicit):
    sso (Authelia forward-auth, groups default [ "admins" "app-<name>" ]), anubis (proof of work), waf (CrowdSec
    AppSec + OWASP CRS / ModSecurity rules), crowdsec (bouncer/bans), rateLimit and inflightLimit (named defaults),
    bodyLimit (default), botDefense (robots.txt, llms.txt, labyrinth), secureHeaders, accessLog (client ip logged),
    homepage card, uptime probe/alert.
- Per service telemetry toggles, ALL DEFAULT ON: metrics (scrape path/port when the service exports any; cadvisor
  resources always), logs (Loki), traces (Tempo/OTLP env injected), profiles (Pyroscope env injected), dashboard
  (generated Grafana dashboard), alerts (generated: down, 5xx ratio, latency, deploy failed, resource saturation).
- Secure by default means opting OUT is explicit and visible: e.g. a public app sets `sso = false`; native clients
  (git, Home Assistant app, tailscale, docker/nix pushes) set `waf = false` / `anubis = false` with a one-line why.
  The existing per-route exemptions (noAppsecRouters, auth = "own", anubis prefixes, searxng no access log, ...)
  become such explicit opt-outs in the owning instance.nix / app.nix; the ingress modules derive everything from
  the schema and keep no per-service lists.
- Policy laws: every exposure resolves to a complete middleware chain matching its toggles; every opt-out carries a
  reason string (field `why`); tests assert the chain per toggle combination (table test) and in the edge VM test.

## Addendum 3: keep it small, primitives first (user)
User: "keep the code duplication minimal. This is already a very big Nix repository and we don't want it to get out
of hand. Focus on the primitives and have them work together nicely. Look at my style skill. Treat this as an actual
programming project. Keep things neat."
- Net line count of the repo should go DOWN. Find the few primitives first (instance, service/exposure, zone,
  flow/grant, secret, token, telemetry target) and build every consumer as a small function over them; no
  per-service special cases in consumers, no second representation of the same fact, no feature that only works
  alone.
- Abstractions only where two real call sites exist and they remove a problem; no speculative options.
- l-style core: subject_verb_object naming, units in names, every literal a named constant defined once,
  one-line why-comments only (no comment stacks, no what-comments), module header block for longer rationale,
  banner sections lowest level first (CONSTANTS, TYPES, INTERNAL, FUNCTIONS), ASCII only, zero lint findings.
- Every agent reports lines added/removed (git diff --stat) and what duplication it removed.

## Addendum 4: a composable set of deployment properties (user)
User: "focus on all of the best practices. Firewalls, isolation, backups. Granular resource allocation. Security
proxies. Telemetry, tracing, alerting. Grafana dashboards. Apps should also be able to shut down if they don't get
traffic, only if we configure that, with a time. Like a very nice composable system of properties a deployment can
have."
The shared schema is a set of orthogonal properties; any deployment (NixOS instance service or swarm app) composes
them, each with a secure default, each implemented once and interacting predictably with the others:
- exposure: host/path/zone/port/health (Addendum 2).
- protection: sso, anubis, waf, crowdsec, rate/inflight/body limits, botDefense, secureHeaders, accessLog
  (default on).
- network: firewall flows/grants (who may reach which port, egress class); default deny, explicit grants.
- isolation: no privilege, read-only root where possible, dropped capabilities, own network, own uid range,
  per-service secrets only (default on).
- resources: cpu/memory reservations and limits, pids, io and log rate, replicas; defaults plus admission.
- backup: volumes and database dumps, schedule, retention, restore test (default on for anything stateful).
- telemetry: metrics, logs, traces, profiles, dashboard, alerts (default on).
- idle: OFF by default; when set (`idle.stopAfter = <duration>`) the deployment stops after that long without
  traffic and the ingress wakes it on the next request, holding the request until healthy. ONE mechanism for both
  kinds: NixOS VMs (today's modules/on-demand.nix wake proxy and reaper) and swarm apps (scale the service to 0,
  wake by scaling to its replicas through a narrowly scoped manager action, never a general docker socket).
  Interacts with: probes/alerts (an idle-stopped deployment is not "down"), backups (run while stopped or wake for
  them), deploys (a deploy of a stopped app does not wake it unless asked), dashboards (show stopped state).
Each property gets a table test of its derivation and a policy law; the VM tests cover their interaction.

## Addendum 5: guest kind derived, apps internal or external (user)
User: "maybe the system can then also automatically decide if it deploys something as a VM or a LXC. In addition,
we can use this new system to configure both internal and external apps as well."
- `vm.kind` is derived from the instance's properties, not hand-picked: one small, documented rule over what the
  guest needs (e.g. GPU or other passthrough, its own docker/podman or swarm, kernel modules or custom sysctls,
  NFS server, running in the external zone where the stronger isolation of a VM is wanted, anything that would
  need a privileged container) -> vm; everything else -> unprivileged lxc. Privileged LXCs disappear: an NFS
  client LXC gets its share bind-mounted from the Proxmox host instead, or becomes a VM, whichever the rule says.
  An explicit `vm.kind` override is allowed only with a `why`.
- Changing a guest's kind recreates it. Report every instance whose derived kind differs from today's, with its
  local state; never flip one silently: list the flips as user decisions/steps (back up, recreate, restore).
- Swarm apps and NixOS services are exposed internally (internal ingress, Authelia) or externally (edge, Anubis,
  WAF) by the same `exposure.zone` field; an app may have both kinds of routes. Same properties, same defaults.

## Addendum 6: placement is a property too (user chose "dedicated guest per app")
User: "With that, we can also deploy apps into the internal and external subnet." / "if we compose simple
primitives, we get much more flexibility."
- A deployment = source x placement x the other properties. Source: a NixOS config (instance main.nix) or a repo
  stack (built by the app builder, images in the registry). Placement: `swarm` (apps zone, vm 250+, default for repo
  stacks) or `guest` in a zone (internal 1xx, external 200-249, default for NixOS configs).
- A repo stack with `placement = { kind = "guest"; zone = "internal" | "external"; }` generates its own guest in that
  zone's vmid range (allocated from data, asserted unique), kind from the vm/lxc rule (an own container runtime ->
  vm), running the built images with podman from the same rendered stack (same swarm-render policy: digest pins,
  no privilege, limits), redeployed by the builder over the same narrowly scoped deploy action. No swarm traffic
  crosses zones.
- Every other property (exposure, protection, network, isolation, resources, backup, telemetry, idle) applies
  unchanged whatever the placement: that is the point of composing primitives. One implementation per property;
  placement only chooses the backend that realises it.

## Addendum 7: one runtime for every repo stack (user)
User: "if I define an app by Docker files, it should run on one guest vm in swarm configuration."
- Supersedes the podman runner of Addendum 6. A repo stack always runs under docker swarm. Placement `swarm`: the
  shared apps-zone cluster (manager vm-140, workers 250+). Placement `guest`: its own generated VM in the chosen zone
  that is a single-node swarm (manager and worker on the guest, autolock, encrypted overlays, the same swarm module
  in a single-node role), deployed with the same rendered stack (swarm-render) and the same scoped `docker stack
  deploy` action. One runtime, one deploy path, one render policy; placement only picks the cluster.

## Line budget (user: "we do not want hundreds of thousands of lines for something we could have done in 5K")
Measured 2026-10-06 (code files under src/, excluding *.md, *.json, secrets, lock and state):
- last commit (Generation 444): about 18.6k lines non-test, 1.7k test.
- working tree now: 24.3k non-test (+5.7k), 9.6k test (+7.9k).
Target at the end of the restructure: non-test BELOW 18.6k (net down despite the new features), tests compact
(table-driven over shared harness helpers, no copy-pasted scenarios). Every agent reports its own +/- in these
two buckets with: git ls-files src | grep -vE "secrets|host-keys|tfstate|\.lock|\.json$|\.md$" | xargs cat | wc -l
Clarification (user): "that doesn't mean to obfuscate things. Keep things simple. It takes as many lines as it
takes, but don't overdo it." The budget is a smell detector, not a golf score: readable, plain code first; no
clever one-liners, no dense combinators, no packing; lines go down by removing duplication and special cases.

## Addendum 8: rebuild only what changed, registry as the build cache; speed and ease of deploy (user)
Today (scripts/app-builder.py): the app is skipped when its head (or watched paths) and build config are unchanged,
but a new commit rebuilds EVERY service of the app; layer reuse comes only from appbuild's local docker cache
(pruned daily to 20GB, gone if vm-117 is rebuilt); the registry is not a build cache; GIT_COMMIT/LAST_UPDATED
build args change on every commit and bust the cache from the first layer that uses them.
Wanted (user: "focus on speed and ease of deployment"):
- Per-service content key: git tree hash of the service's build context + dockerfile + target + args (not the
  commit). An image with that key already in the registry is reused by digest: no build, no push.
- BuildKit with the registry as cache (--cache-from/--cache-to type=registry,mode=max, per-service cache ref), so a
  fresh vm-117 or a pruned local cache still reuses layers; the registry prune keeps cache refs bounded.
- Commit metadata as labels/annotations added after the cached layers, never invalidating build layers.
- Speed: services of one app built in parallel (bounded by the builder's cpu), only changed services redeployed
  (unchanged digests leave their swarm services untouched), commit-to-live latency measured as a metric and shown
  on the app's dashboard; the poll stays cheap (one ls-remote per app) unless a push trigger is simpler.
- Ease: adding an app is one folder apps/<name>/app.nix with repo + branch (everything else defaulted);
  `app-builder-redeploy <app>` and status in one place; errors name the fix.
- Tests: table/simulation in the app-builder check (unchanged service -> no build; changed context -> only that
  service rebuilt; cache ref used; parallel builds bounded); metrics built/skipped per service.

## Addendum 9: frontend telemetry, global + per-service dashboards, the app's own reverse proxy (user)
User: "also support OpenTelemetry from the front end. Logs, metrics, performance traces from the back end; telemetry
from the backend and from the front end. When I define a new app: this URL, those three Dockerfiles, one of them a
reverse proxy: build everything, store builds in the registry, on update cache everything it can, auto-generate a
Grafana dashboard per app. One global dashboard which shows everything, then a per-service dashboard."
- Frontend telemetry is part of the telemetry property (default on): every exposed app gets a browser OTLP/HTTP
  intake on its own origin (e.g. `<host>/otlp/v1/{traces,logs,metrics}` routed by the ingress to a collector), so no
  CORS dance and no third-party endpoint; per-app tenant and limits like the backend; strict rate/body limits since
  it is unauthenticated public input; attributes allow-listed (no cookies, no query strings, no PII); the
  `traceparent` header propagates from browser to backend so one trace spans frontend and backend. The app's
  frontend only needs the standard OpenTelemetry web SDK pointed at a relative `/otlp` (document the snippet).
- Dashboards: ONE global overview (every deployment: up/idle/down, traffic, errors, latency, resources, deploys,
  alerts firing, budget per tenant) linking to ONE generated dashboard per service (backend metrics/logs/traces/
  profiles + frontend web vitals, errors, frontend traces + edge + resources + deploys), both from the same generator.
- An app's stack may contain its own reverse proxy (one of its services); the exposure points at that service; the
  proxy must see the real client ip (edge sets X-Forwarded-For/X-Real-Ip, the stack trusts only the swarm/edge
  sources) and plain http inside (tls ends at the edge).

## Addendum 10: one deploy controller (user)
User: "in reality that means we have one swarm manager VM which does all of the deploying and creating of Grafana
dashboards, and the building and the caching."
- vm-140 (internal, the apps-cluster manager, drained of tasks) becomes the single deploy controller: it builds
  (the rootless `appbuild` user and its BuildKit cache move here from vm-117), pushes to the registry, and deploys to
  every cluster (the shared apps swarm locally, guest single-node swarms over the scoped deploy action). vm-117 keeps
  only CI runners. Build isolation stays: builds run rootless as `appbuild`, never as root and never against the
  swarm's root docker socket; appbuild's egress is the owner-match allow-list (internet, registry, nothing else in
  the lab); the swarm unlock key and join tokens are root-only.
- Dashboards and alerts stay declarative: generated from the same app data at evaluation time and provisioned into
  Grafana on vm-105 (no runtime generator, no Grafana write credential anywhere). An app enters the catalog through a
  sync, so its dashboard appears in the same sync. The controller only adds runtime facts (deploy metrics).

## Addendum 11: poll every 30 minutes plus a keyed redeploy endpoint for CI (user)
User: "the swarm manager should pull every 30 minutes to see if a deployment has to be done. But there should also be
an endpoint swarm-manager.lsck0.dev/redeploy so I can start that from a CI, protected by a key."
- The controller's poll timer runs every 30 minutes (named constant), not every minute.
- `POST https://deploy.<domain>/redeploy/<app>` with `Authorization: Bearer <token>`: one token per app (a generated
  secret in apps/<name>/, to be stored as a CI secret of that app's repo), compared in constant time. The endpoint
  only schedules that app's normal check now (it starts `app-builder@<app>`); it takes no ref, image or payload, so
  a leaked token can at most trigger a rebuild of the configured branch: idempotent, coalesced while a run is busy,
  rate limited. Answers 202 / 401 / 404 (unknown app) / 429.
- Exposed through the schema like any service: external zone, sso and anubis off (machine client, with a why), waf,
  crowdsec, tight rate and body limits, POST only on that path, access log on. The listener on vm-140 is
  socket-activated (idle costs nothing), runs unprivileged, and can only start the per-app unit (polkit/sudo rule
  scoped to that unit template).
- README / app docs: the one-line CI step (`curl -fsS -X POST -H "Authorization: Bearer $DEPLOY_TOKEN" ...`).
- Tests: wrong/missing token 401, other app's token 401, unknown app 404, burst 429, valid token starts exactly one
  run, a second request during a run coalesces.

## Addendum 12: apps bring their own dashboards (user)
User: "Dashboards can stay declarative, but every app should be able to say: this is my dashboard JSON, and it
should be included into Grafana."
- telemetry.dashboards = [ "<path or glob in the app repo>" ] (default: none). At deploy the controller reads those
  files from the exact commit it deploys and writes them, normalised, into the app's folder on a provisioning share
  that Grafana on vm-105 reads read-only with its file provider (no Grafana write credential anywhere; a removed app
  or file disappears on the next deploy/converge).
- Normalisation: uid prefixed with the app name (no collisions), placed in the app's Grafana folder next to the
  generated dashboard, every datasource reference rewritten to the app's own tenant-scoped datasources (an app's
  dashboard can never query another app's data), size limit, invalid JSON refused with a deploy error naming file
  and reason.
- Tests: table test of the normaliser (uid prefix, datasource rewrite, foreign datasource refused, oversize
  refused); the VM test's app ships one dashboard and Grafana serves it under the app's folder.

## Addendum 13: the organising picture, a hosting company (user)
User: "Think of this as a company that hosts for you. We need internal software. We need external software. And we
need the actual part where the users deploy."
Three planes, the README and the tree say so in these words:
1. Platform (src/modules + the platform instances: router, ingresses, identity, telemetry, storage/NAS, registry,
   deploy controller): what every deployment composes; owned by the operator.
2. Company software: instances/ (NixOS configs or repo stacks placed as guests), internal zone (staff only, behind
   Authelia) and external zone (public, behind the edge).
3. Customer deployments: apps/<name>/ = one tenant each, on the apps swarm (or its own guest), self-service: repo +
   branch + optional properties, deploy token for its CI, its own dashboards/alerts, its own quotas.
Tenant boundaries (an app = a tenant) are first-class and enforced by the existing properties, not new machinery:
own overlay network and secrets (isolation), own registry repository scope and deploy token, own telemetry tenant
and limits, own resource quota with admission, own Grafana folder visible to its lldap group `app-<name>` (plus
admins), no route into platform or company zones (network). One tenant can neither see nor starve another; the
global dashboard shows usage per tenant (resources, requests, telemetry volume) like a provider's console.
Clarification (user): "We don't actually want to make a company, but this is the level of things I want." The
hosting-company picture is the quality bar (isolation, self-service deploys, observability, quotas), not a product:
no customer/tenant/billing vocabulary or features, no accounts beyond the existing lldap groups. Docs say platform,
instances (internal/external) and apps; per-app usage panels stay, nothing that meters or charges.

## Addendum 14: apps are the user's own products for end users, http and raw tcp/udp (user)
User: "if I in the future provide game servers or web apps for users, those should land in the swarm nodes and be
very, very carefully monitored, secured and independent."
- apps/ holds the user's own products (web apps, game servers), not other people's code; they run on the apps
  swarm (or their own guest) with every isolation/monitoring property on.
- exposure must cover non-HTTP: `protocol = "http" | "tcp" | "udp"` with a public port. tcp/udp exposures are
  forwarded by the router (WAN port -> the apps nodes' published port, from the flows data, like today's minecraft
  forward generalised; minecraft becomes the first such exposure), with L4 protection as the defaults of the
  protection property: per-source new-connection rate and concurrent-connection limits, a global per-exposure cap,
  CrowdSec bans enforced on the router (firewall bouncer) for these ports, logging of client ips. Ports unique and
  asserted; DDNS/DNS records derived.
- Telemetry for tcp/udp exposures: connections, bytes, drops by limit, per app on its dashboard; probes per protocol.
- A game server is typically stateful: backup property (volumes, schedule, restore test) and idle stop (an empty
  server stops after its window; the router-side wake for tcp is the same idle mechanism, for udp say what is
  feasible, else idle unsupported for udp with a clear evaluation error).

## User decisions after review 2 (2026-10-07)
- The internal zone reaches everything (Proxmox host, house LAN, every zone): review2 finding #3 is rejected, do not restrict
  internal egress. Compensating controls stay in scope (e.g. #4: second factor and ldaps for the Proxmox lldap realm).

---

# Appendix B: cleanup and data-safety rules (CLEANUP.md)

# Cleanup pass (user: "get rid of all of the comment spam and hacks", "keep the lines minimal and clean, but don't
# obfuscate; it takes as many lines as it takes")

Per file you own:
- Comments: keep only a one-line why where the reason is not obvious from the code; delete what-comments, history,
  restated names, stacked multi-line comment blocks (fold into one line or into the module header block when the
  rationale must stay), banners only where l-style asks for sections. ASCII only, no " - " connectors.
- Hacks: any workaround, sleep, retry-until-it-works, `|| true`, magic number or string, duplicated literal,
  dead option, dead branch, unused let binding, unused file: fix the root cause, name the constant once, delete the
  dead thing. If a real fix is out of scope, leave it and list it in your report with the reason.
- Duplication: a fact stated twice becomes one definition used twice; prefer reading from the collector (`lab`,
  catalog, net, telemetry constants) over local literals.
- No behaviour change unless removing a hack requires it (then state it). Plain readable code; no packing.
Verify: every touched host still evaluates; for files where only comments changed in .nix, the host drvPath must be
identical (nix comments do not reach derivations); for script/config changes, run the checks that cover them (one
VM test at a time). Report lines before/after per file group and anything you deliberately left.
Rules: fixphase/OWNERSHIP.md "Rules for every agent"; `rm` is `trash` (use git mv/mv); never sync.sh, ssh, commit,
decrypt; new files `git add -N`; re-read before every edit (other agents still fix test failures in shared files).
DATA SAFETY (user: "just don't destroy any data"): never change anything that addresses persistent data without a
migration that keeps it: state dir paths, NFS share names, volume names, database names/users, uids/gids that own
files, sops secret names whose values cannot be regenerated, kopia/backup repository settings, terraform resource
keys or disk definitions. If a cleanup would touch one of these, leave it and list it.

---

# Appendix C: test harness API (HARNESS.md)

## Harness API (from agent F; source of truth: src/tests/lib/*.nix headers + README test section)
- New files must be registered with `git add -N <file>` (intent-to-add) so the flake sees them. Never commit.
- Test signature: `{ pkgs, lib, inputs, specialArgs, seed ? <default>, ... }`; seeded tests print `seed=<n>` first and list
  failing seeds in `passthru.regressionSeeds`; rerun one seed: legacyPackages.x86_64-linux.seeded.<name>.<seed>.
- `lab = import ./lib/lab.nix { inherit pkgs lib specialArgs; }`; set `node.specialArgs = lab.specialArgs;`.
- Nodes: `lab.guest "<vmid>" { flat ? false; vlan ? <zone vlan, 1 when flat>; instance ? null; nas ? false; }` (production
  stack at the inventory address on eth1); `lab.router` (real router, ens18..ens21 on vlans 1..4 + offline-router.nix);
  `lab.nas { flat ? false; vlan ? ...; }` (vm-109 real export rules over the test's nodes); `lab.multi { addresses = [ "a/p" ]; vlan ? 1; gateway ? null; routes ? [ ]; }`.
- Values: lab.vlans { lan=1; internal=2; dmz=3; apps=4; }, lab.production, lab.inventory, lab.site, lab.nasClients,
  lab.appsCatalog, lab.pki (.ca, .lsck0.{cert,key}, .github.{cert,key}), lab.secretValues, lab.labprobe,
  lab.images (registry, registry-ui pinned; labprobe; crowdsec-stub).
- Catalog override in tests: `homelab.appsCatalog = lib.recursiveUpdate lab.appsCatalog { apps.wat.enable = true; }`.
- Driver python: `testScript = lab.driverPython + ''...''`: probe_sinks_start(machines, tcp=(..), udp=(..), esp=False);
  probe_check(plan, sources={ip: machine}, sinks=[machines], seed=SEED, timeout_ms=700) with plan entries
  {src, dst, proto, port, expect: open|closed|refused|filtered|unreachable, seen_src?};
  http_request(machine, url, address=, src=, method=, headers=, body=) -> {status, headers, body, body_bytes}.
- lib/offline-traefik.nix on top of 100/200: bans in /var/lib/crowdsec/data/stub-bans, calls logged to stub-calls.jsonl,
  AppSec 403 on `X-Test-Attack: 1`; plugin caches verdicts ~60 s per client ip: ban before the first request.
- Flat tests: the `world` multi node must also own the gateways (10.100.0.1/8 etc.).
- Stubs: tests/stubs/sops.nix (restartUnits, testing.secretValues, testing.honorSecretPermissions; placeholders replaced at
  activation), tests/stubs/nas.nix, tests/stubs.nix imports all. NAS mounts: homelab.nasMounts (modules/nas.nix);
  guests bind local dirs by default (lib/nas-local.nix), `nas = true` mounts from lab.nas.
- Policy laws: src/tests/policy/<area>.nix = { lib, configs, inventory, site, nasClients, appsCatalog, catalog, ... }:
  [ "violation" ... ]; run by check policy-eval. Example: policy/ports.nix.
- Example tests: tests/harness-smoke.nix (router + guests + probes), tests/swarm.nix (nas = true).

---

# Appendix D: review-2 report (REPORT.md)

## Homelab review 2: final report

Date: 2026-10-07, Generation 448. This report covers seven review dimensions: primitives, security, secrets-data, platform, instances, tests-tooling and operations. Every finding passed an adversarial verify pass. When several dimensions found the same root cause, they are merged into one entry that lists every place. Severities are the verified ones. Where dimensions disagreed, the entry says which rating was kept.

## Executive summary

1. **Solid:** the collector design holds (one instance.nix per folder, collected once). policy-eval and every eval-only check pass, and `systemctl --failed` is clean on every guest I could reach.
2. **Solid:** backups are fresh (NAS daily 36 min old, db dumps under 1 h, off-site 22 h). Terraform state matches all 27 VMs and 7 CTs, DDNS is current, the secrets plan is clean, and images are pinned by digest.
3. **Top risk, live:** the internal ingress vm-100 is down now. Its balloon floor is 512 MiB. Across the host, balloon floors add up to 43 GiB on 32 GiB of RAM, and the host is swapping the router.
4. **Top risk, live:** the Proxmox firewall is off, so ipfilter and macfilter do nothing. Meanwhile every guard, NFS export and trustedProxies setting decides access by source IP.
5. **Top risk:** the internal zone can reach the Proxmox API and SSH. Proxmox Administrator through the lldap realm needs only the SSO password, and that password is sent as plaintext LDAP.
6. **Top risk:** the homepage and collector grants open every backend port to vm-103 and vm-105, which bypasses Authelia. Affected: paperless (trusts Remote-User), kopia (no password), filebrowser and the registry (no auth).
7. **Top risk:** Loki takes the tenant from the client and serves queries to the DMZ edge and the workers. Separately, terraform sends the Administrator token with TLS verification off.
8. **Top risk, data:** after a kopia restore of a localState service, the next mirror run overwrites the restored copy. Eight services, plus Prometheus and Loki, still keep databases on hard NFS mounts.
9. **Broken live:**
   - On-demand wake and reap fail silently, because the Proxmox certificate does not include the new IP.
   - A GitHub runner is looping through 700+ restarts.
   - A stale metric pages "deploy failed" all the time.
   - Pingvin Share lets anyone sign up.
10. **Common thread:** one fact often has several copies: grants, roles, `enabled`, the apps catalog, the Proxmox CA, host keys and host config owners. Most medium and low entries go away once a few missing primitives exist.

## Ranked findings

Totals: 1 critical, 12 high, 42 medium, 39 low.

### 1. Internal ingress vm-100 is down: ballooned to 512 MiB on an overcommitted host
- **Severity:** critical. Security and instances; operations rated the host overcommit high, merged here.
- **Where:**
  - src/instances/100-internal-traefik/instance.nix:3-7 (memoryMiB 1024, no balloonMiB)
  - src/modules/instance-schema.nix:150-155 (floor is max(512, mem/2))
  - src/instances/119-internal-archbuild/instance.nix:6-8
  - Proxmox host 192.168.178.200
  - No capacity law exists; src/modules/limits only admits swarm apps.
- **Evidence:**
  - vm-100: balloon = balloon_min = 512 MiB, freemem about 60 MB, page-cache thrash at about 1.1 GB/s of disk reads. SSH times out at banner exchange, and auth.lsck0.dev returns 000 after 8 s.
  - Host: about 27 of 32 GiB used, 3.5 GiB swap. The router (216M) and the NAS (185M) are partly swapped out.
  - Totals: balloon floors 37632 MiB (balloon 0 counted in full), LXCs 5376 MiB, ARC max 3.2 GiB.
  - vm-200 sets balloonMiB = 1024 by hand; vm-100 does not.
  - vm-119 logged a cc1plus OOM kill at 01:51.
- **Impact:**
  - Every internal route, SSO, the edge relays and registry pulls are down.
  - It recurs whenever a large guest pushes the host past the autoballoon line.
  - The swapped router and NAS add latency to every flow.
  - Nothing stops the next instance from making it worse.
- **Fix:**
  - Add a host memory budget law: floors + LXC limits + ARC max + a named reserve must be at most host RAM. It fails evaluation and prints the totals.
  - Declare the ingress stack's memory floor once in modules/traefik and derive memoryMiB and balloonMiB for both ingresses from it.
  - Make network and public bootPhase guests default to balloonMiB = memoryMiB.
  - Make the numbers fit using entries 9, 32 and 31.
  - Add a PSI alert.

### 2. The Proxmox firewall is off, so the lab has no anti-spoofing while every guard trusts source IPs
- **Severity:** high. Security; also merges tests-tooling's "Hermes skill describes an inactive firewall".
- **Where:** src/terraform/main.tf:84-88; src/terraform/lib.tf:280-330; src/instances/300-router/main.nix:9-10; src/instances/114-internal-hermes/lib/skills/proxmox/SKILL.md:32
- **Evidence:**
  - `pve-firewall status` gives `disabled/running`, and cluster.fw has `enable: 0`.
  - The per-guest ipfilter and macfilter settings exist but do nothing.
  - The router comment and the Hermes skill both claim the firewall binds each guest to its address and MAC.
  - lib.tf points to a README section "Proxmox firewall" that does not exist.
- **Impact:** root on any guest can take a neighbour's address with a gratuitous ARP.
  - As 10.100.0.100, it passes every internal guard and can forge Remote-User.
  - As 10.200.0.200, it inherits the edge's flows and trusted X-Forwarded-For.
  - As a NAS client's address, it can mount that client's export.
- **Fix:**
  - Default proxmox_firewall to true and apply it.
  - Add a check that fails while the firewall is off.
  - Fix the skill and add the missing README section.
  - Trust container traffic by input interface, not by 172.16.0.0/12 arriving on any interface.

### 3. The internal zone reaches everything, including the Proxmox host and the house LAN
- **Severity:** high (security)
- **Where:** src/modules/flows.nix:84 (`reaches = "everything"`)
- **Evidence:** from vm-121, Proxmox :8006 returns 200, and the host's :22 and the workstation's :22 are open.
- **Impact:** any compromised internal app, including the third-party containers, is one hop from the Proxmox login, SSH and every house device.
- **Fix:** give internal the same policy as the DMZ: internet plus named flows. Add explicit flows for operators that need more (hermes and the workstation to Proxmox, vm-109).

### 4. Proxmox Administrator through the lldap realm takes a password only, over plaintext LDAP
- **Severity:** high (security)
- **Where:** src/scripts/pve-install.sh:160-175; src/instances/101-internal-authelia/lib/lldap.nix:131,148
- **Evidence:**
  - The realm uses `mode ldap` to 10.100.0.101:3890 with no TFA, and the TFA list is empty.
  - admins-lldap has Administrator on `/`.
  - The lldap admin password is reused from the Authelia admin.
- **Impact:** the SSO password alone gives datacenter admin, with no second factor, and it is sent in cleartext.
- **Fix:**
  - Turn on TOTP or WebAuthn for the realm.
  - Use ldaps, or starttls with certificate verification.
  - Restrict port 8006 to the ingress and the workstation once entry 2 is fixed.
  - Give the lldap admin its own generated secret.

### 5. Prober and status-dot grants open every backend port to vm-103 and vm-105, bypassing Authelia
- **Severity:** high. Security; also merges secrets-data's "kopia has no password and is reachable from 103/105".
- **Where:** src/modules/flows.nix:232-235; 109 lib/kopia.nix:204-205; 109 main.nix:196-205; 118 main.nix:62; 121 main.nix:77; 130 lib/servarr.nix:32
- **Evidence:**
  - From vm-103, without credentials:
    - registry `/v2/_catalog` returns 200
    - kopia :51515 returns 200
    - filebrowser login with `{}` returns 200
    - paperless returns 200 when sent `Remote-User: luca`, and 302 without it
  - Grafana is not affected: its auth.proxy whitelist rejects vm-103 with 401.
- **Impact:** compromising the homepage container or grafana gives:
  - any user's paperless documents
  - kopia restore and delete over the whole NAS history
  - the NAS tree as uid 1000
  - registry push, which then deploys to the workers
- **Fix:**
  - Probe through the ingress, with a health exemption or a probe identity limited to GET on the health path, then delete this grant.
  - Give the registry its own htpasswd.
  - Give kopia `--server-username` and `--server-password` from sops.

### 6. Terraform sends the Administrator API token with TLS verification off
- **Severity:** high (tests-tooling)
- **Where:** src/scripts/init.sh:222; src/terraform/main.tf:99-102; sync.sh:393-397
- **Evidence:**
  - init.sh writes `proxmox_insecure: true`.
  - terraform-prov@pve has Administrator on `/`.
  - sync.sh already pins the certificate for its own curl calls.
- **Impact:** a host that spoofs the Proxmox address on the LAN gets the datacenter-admin token on every sync.
- **Fix:** drop proxmox_insecure. Export SSL_CERT_FILE pointing at site.proxmoxCa for terraform. This needs entry 9's certificate fix.

### 7. Loki takes the tenant from the client and serves queries to the DMZ edge and the app workers
- **Severity:** high. Security; also merges platform's "workers can read every Loki tenant".
- **Where:** src/instances/105-internal-grafana/main.nix:1068,1334-1344,1597-1600; src/modules/flows.nix:76,135
- **Evidence:** the tenant comes from the X-Scope-OrgID header for all of `/`. From vm-200, the labels and query endpoints return 200 with every host's data.
- **Impact:** a compromised edge or worker can read every journal and access log, including the feed tokens of entry 22. It can also inject log lines into any tenant.
- **Fix:**
  - Senders get only `/loki/api/v1/push`, with the tenant set from the sender's address.
  - Queries are served only to loopback and the named readers (vm-104, vm-114).
  - Better still, give push its own port.

### 8. Restoring a localState service from kopia does nothing, and the next mirror overwrites the restore
- **Severity:** high (secrets-data)
- **Where:** src/modules/local-state/default.nix:58-111; 109 lib/kopia.nix:98-113; 114 lib/skills/backups/SKILL.md:53-68; 109 tests/kopia.nix:12-40
- **Evidence:**
  - The seed is skipped while `.seeded` exists.
  - The mirror runs `rsync -a --delete` from local to NAS on a Persistent timer.
  - `nas-restore service` writes only to the NAS directory.
- **Impact:**
  - Six services (grafana, homeassistant, jellyfin, jellyseerr, paperless, paperless-ai) restart on their broken local copy.
  - The next mirror then wipes the restored NAS copy. The restore reports success.
  - Hermes runs this procedure on its own.
- **Fix:**
  - Write a matching generation id into both copies; when they differ, the mirror refuses and alerts.
  - Add a `<name>-reseed` unit.
  - Export the localState shares so nas-restore can drive the reseed.
  - Fix the kopia test, and add a localState restore test.

### 9. On-demand wake and reaper cannot reach the Proxmox API: the certificate lacks 192.168.178.200
- **Severity:** high (instances, operations)
- **Where:**
  - Proxmox pve-ssl.pem
  - src/modules/on-demand/default.nix:55-66,162-189,224-227
  - src/modules/infra.nix:13
  - 100 main.nix:55-57
  - 103 main.nix:125-128
- **Evidence:**
  - The certificate's SAN lists only 127.0.0.1, ::1, localhost, 192.168.178.2 and the luca-server names.
  - From vm-200, curl fails with error 60 (SAN mismatch).
  - A failed curl yields an empty status, so the reaper exits silently.
  - The onDemand guests have been up 3-4 h against a 30-60 min stopAfter.
- **Impact:**
  - Once a guest is stopped, its route holds each request for 180 s and then fails.
  - wakeAt starts nothing.
  - About 6.4 GiB of idle guests stay resident.
  - The Proxmox route and the homepage widget fail the same way, and nothing alerts.
- **Fix:**
  - In pve-install, compare the SAN with site.lan.proxmox; if the address is missing, run `pvecm updatecerts --force` and reload pveproxy.
  - Treat an API failure as an error, export `homelab_ondemand_api_ok`, and alert on it.

### 10. Pingvin Share is public with open registration, unlimited expiry and settings only in its database
- **Severity:** high (instances)
- **Where:** src/instances/207-external-share/main.nix:11-21; instance.nix:15
- **Evidence:** registration is on, max expiration is "0 days" (unlimited), max size is 1 GB, and appUrl is localhost (the APP_URL env is never applied).
- **Impact:** anyone on the internet can host files indefinitely under the owner's domain and IP.
- **Fix:** mount a declared config.yaml with registration off, a finite expiry and appUrl taken from the catalog. Alternatively, limit the SSO opt-out to `/s/`.

### 11. "App deploy failed" pages permanently from a stale textfile left on vm-117
- **Severity:** high (operations)
- **Where:** vm-117 textfile `app_builder.prom`, `/var/lib/app-builder`, `/var/lib/appbuild`; 105 main.nix:723
- **Evidence:** a stale 0 from 10.100.0.117 beats the 1 from vm-140 under `min by (app)`. The rule fired 10 times in 10 minutes, with Telegram on.
- **Impact:** a permanent page trains the owner to ignore it and hides real failures.
- **Fix:**
  - Have each textfile job write into a directory systemd owns, or prune undeclared *.prom files on activation.
  - Scope the rule to the builder instance.
  - Remove the leftovers on vm-117 by hand.

### 12. github-runner-nyangine is in a crash loop (700+ restarts), invisible to `systemctl --failed`
- **Severity:** high (instances)
- **Where:** src/instances/117-internal-github-runner/main.nix:53-92,117
- **Evidence:** NRestarts=733 with "Permission denied" on mkdir. `/var/lib/github-runner` is owned by uid 994, which no longer exists.
- **Impact:** the benchmarks cannot run, and the loop makes about 270 root-run GitHub token mints per hour.
- **Fix:** add a tmpfiles `d` rule for the parent directory, remove the stale registration dirs, and alert on climbing NRestarts.

### 13. tcp/udp app exposures (Addendum 14) cannot work
- **Severity:** high. Platform; latent, no app uses it yet.
- **Where:** swarm-render.py:355-358; swarm/default.nix:215,588-594; catalog.nix:142-148; flows.nix:221-225
- **Evidence:**
  - Every port is published as tcp.
  - The worker guard drops router-DNATed WAN clients.
  - The router forwards to `lib.head r.nodes` only.
- **Impact:** the schema accepts a feature that can never answer.
- **Fix:**
  - Carry the protocol through to the published port.
  - Give l4 routes their own port group open to anywhere.
  - Forward to every cluster node.
  - Add a VM test.

### 14. Runtime tokens are a second secrets channel; *arr keys are mined by sed-editing config.xml
- **Severity:** medium (secrets-data, primitives)
- **Where:** src/modules/retry.nix:63-77; modules/tokens; 112 main.nix:125; 125 main.nix:176; 130 lib/servarr.nix:28-60,101-112
- **Evidence:**
  - Five lab-chosen passwords are generated with `openssl rand` and stored 0644 on NFS.
  - The *arr setup runs sed on config.xml, stops and starts the container, then greps out the ApiKey, with two layers of retry.
  - The pinned images support the `<APP>__AUTH__APIKEY` environment overrides.
- **Impact:** these values skip the plaintext guard, rotation and encryption, and they exist only after a boot converges.
- **Fix:** declare them as sops `hex:16` secrets passed through the environment, and keep the token share for values the apps mint themselves. Roll out in coordination with consumers.

### 15. Databases on NFS despite the localState primitive: 8 SQLite services plus Prometheus, Loki, Pyroscope
- **Severity:** medium (secrets-data, operations)
- **Where:** 130 servarr.nix; 115 main.nix; 138 main.nix; 136 main.nix; 105 main.nix:1032-1035; nas.nix:11
- **Evidence:** 46 "database is locked" lines in 7 days on vm-130. The telemetry stores sit on `hard` NFS mounts.
- **Impact:** forgejo and headscale run on a setup the repo itself calls corrupting. When the NAS hangs, monitoring stalls with it.
- **Fix:**
  - Move the SQLite services to localState (same share name, so the data seeds over).
  - Move the telemetry stores to local disk.
  - Add a law against declared sqlite files on a nasMount.

### 16. Hermes' ssh key is root on the hypervisor and every guest; keys have no scope
- **Severity:** medium. Tests-tooling; security rated it low because root everywhere is the owner's choice.
- **Where:** src/lab/keys/hermes.pub; base/default.nix:63; sync.sh:406-410; 114 main.nix:20-22,228-233,245
- **Evidence:** every key in lab/keys gets root on every host. The key comment says vm-126.
- **Impact:** a prompt injection or a Telegram takeover gets root everywhere, including every age key.
- **Fix:** give keys a scope as data. Default Hermes to a read-only forced-command identity, with root behind confirmation. Regenerate the key so its comment says vm-114.

### 17. A missing data-guarding secret is silently regenerated and deployed
- **Severity:** medium (secrets-data)
- **Where:** secrets-sync.sh:150-162; sync.sh:598
- **Evidence:** kopia-password, authelia-storage-key and the garage rpc secret are plain hex kinds, and `--apply` runs unattended.
- **Impact:** a rename deploys a new key, which locks you out of kopia or authelia.
- **Fix:** add a `guardsData` kind that is never auto-generated after the first deploy.

### 18. The plaintext guard never scans the Proxmox API token: tfvars is not in its value files
- **Severity:** medium (secrets-data)
- **Where:** secrets-check.sh:44-46,69-73
- **Evidence:** the value-file list leaves out terraform.tfvars.sops.json.
- **Impact:** the hypervisor token is the one value that is never value-scanned before a public push.
- **Fix:** build the list from the secrets plan, and mark tfvars' public values so they do not cause false refusals.

### 19. Kopia snapshots are never verified and the off-site copy is never read back
- **Severity:** medium (secrets-data)
- **Where:** 109 lib/kopia.nix:121,209-235,407-414
- **Evidence:** verification is manual only, and proton-sync never reads anything back.
- **Impact:** corruption is found only on the day of the disaster.
- **Fix:** add a weekly verify timer with a metric and alert, and periodically sample off-site blobs.

### 20. One NVMe failure loses every guest and the local backup repository; disk warnings go to dead mail
- **Severity:** medium (operations)
- **Where:** VG pve, linear over two NVMe disks; the kopia repo on vm-109's root disk; host postfix; 105 main.nix:617,628
- **Evidence:**
  - The volume group has no mirror.
  - The 59G kopia repo shares a disk with the data it protects.
  - nvme1 has logged 712 temperature-warning minutes, and 4 SMART mails are queued.
  - No alert rule uses critical_warning or temperature.
- **Impact:** only the Proton copy survives a disk loss, and hardware warnings reach no one.
- **Fix:** add NVMe warning and temperature alerts, relay smartd to ntfy, and move the kopia repo to the bulk HDD or mirror the NVMe pair.

### 21. Alert delivery and the dead man's switch hairpin through the edge; a whole-site outage pages no one
- **Severity:** medium. Operations; critical rules also reach Telegram directly.
- **Where:** 105 main.nix:263,355-398; 203 main.nix:128-151
- **Evidence:** 30 notifier failures since 00:00, and the heartbeat runs on the same host.
- **Impact:** an edge fault drops every ntfy page, and an outage of the whole site pages no one.
- **Fix:** point grafana at vm-203 directly, and add one off-site heartbeat.

### 22. Feed tokens in URL paths go to both ingresses' access logs and into Loki
- **Severity:** medium (security)
- **Where:** base/default.nix:122-140; 104 instance.nix:5-11; 104 main.nix:12-16,47-48
- **Evidence:** the edge access log holds `/<token>/...` paths, which promtail ships unredacted.
- **Impact:** every Loki reader gets the private calendar and all feed URLs.
- **Fix:** add a secret-path service property (or `off.accessLog`) plus a promtail redaction stage.

### 23. The client address has two representations: X-Real-Ip is correct, backends re-derive from raw XFF
- **Severity:** medium (security)
- **Where:** traefik/default.nix:54,63-71,245,300-302,750; 125 main.nix:78-79; 204 main.nix:76; 203 main.nix:89
- **Evidence:** HA sees the edge as the client, searxng sees Cloudflare, and Authelia trusts the leftmost XFF entry, which the client controls.
- **Impact:** per-client defences key on the wrong address or can be forged.
- **Fix:** have the middleware overwrite XFF with the resolved client.

### 24. Anyone on the internet can keep the admin locked out of SSO
- **Severity:** medium (security)
- **Where:** 101 main.nix:183-187; lldap.nix:13; traefik/default.nix:96-99
- **Evidence:** regulation is per user, at 3 tries per 2 min. The username is public, and 3 failures every 5 min stay under the rate limit.
- **Impact:** the admin cannot log in.
- **Fix:** add a crowdsec Authelia scenario, or use IP+user regulation once entry 23 is fixed.

### 25. Per-app telemetry tenants are spoofable: any app container can write and read others' tenants
- **Severity:** medium. Platform; latent.
- **Where:** swarm-render.py:245-251; swarm/default.nix:448-457; 105 main.nix:1110-1113,1171,1184-1185,1594; flows.nix:76,135
- **Evidence:** the tenant is just an env var, and containers can reach the OTLP and Pyroscope ports, which honour the header.
- **Impact:** one app can starve, forge or read another, which breaks Addendum 13.
- **Fix:** put a per-node relay in front that sets the tenant from the stack label, and keep the query API on loopback.

### 26. Unpinned code runs in the auth and signing paths (Jellyfin SSO plugin, archbuild image)
- **Severity:** medium. Instances; also merges tests-tooling's low archbuild-image finding.
- **Where:** 134 main.nix:47-48,460-469; 119 main.nix:19,101,112-122
- **Evidence:** the SSO plugin comes from a branch manifest with no hash. The publish step runs a rolling `archlinux:base-devel` with the signing key mounted.
- **Impact:** code nobody reviewed runs in the only Jellyfin login path and next to the signing key.
- **Fix:** fetch the plugin with fetchzip and a hash, and pin the publish image by digest.

### 27. Host keys and deploy public keys bypass the lab's known_hosts and keys primitives
- **Severity:** medium. Instances; also merges three low findings: security (hermes accept-new), secrets-data (app deploy key) and platform (unused vm-140 deploy door).
- **Where:** archrepo-build.sh:113; 210 main.nix:7; 114 main.nix:248-253; swarm/default.nix:511-519,699-701; 140 instance.nix:33
- **Evidence:**
  - Two places use accept-new: the archrepo push (with `/dev/null` as its known_hosts) and Hermes.
  - Two public keys are hard-coded: the archrepo push key in vm-210, and the app deploy key in the swarm module, whose comment still names vm-117.
  - A forced-command root entry is installed on vm-140 itself, where nothing uses it.
- **Impact:** first-use trust on root and publish keys, and key rotation takes edits in two folders.
- **Fix:** use the generated known_hosts with strict checking everywhere, keep each public key with its owner, and install the forced command only on guest managers.

### 28. Hermes uses CLAUDE_CODE_OAUTH_TOKEN, an unsupported provider path that leaks into every shell it runs
- **Severity:** medium (instances)
- **Where:** 114 main.nix:227-236; instance.nix:15
- **Evidence:** upstream says this path does not work and stops scrubbing the token from terminal environments. The logs show the auxiliary client cannot find credentials.
- **Impact:** inference may fail, and the token sits in every subprocess environment.
- **Fix:** use ANTHROPIC_API_KEY as its own secret.

### 29. Hermes still loads 10 stale skills with contradicting facts
- **Severity:** medium (instances)
- **Where:** 114 main.nix:297-299
- **Evidence:** ten old skill folders remain on the host, with wrong hosts and an ollama fallback the policy forbids.
- **Impact:** an agent with root follows outdated instructions.
- **Fix:** install the skills as one store directory, or prune undeclared ones on activation.

### 30. The image content key ignores the base image, so base-image security fixes never ship
- **Severity:** medium (platform)
- **Where:** app-builder.py:200,393-410
- **Evidence:** the key has no FROM digest, and an existing tag is reused.
- **Impact:** apps whose sources do not change keep their old libc and openssl layers.
- **Fix:** add the FROM digest to the key, or a `BASE_REFRESH_DAYS` term.

### 31. Archbuild's memory bound is a cpuset heuristic with no cgroup limit; OOMPolicy on the unit is a no-op
- **Severity:** medium (instances)
- **Where:** 119 main.nix:29-33,80-82,98-102; archrepo-build.sh:353-359
- **Evidence:** ninja runs 4 jobs on 2 CPUs, there is no `--memory`, and the container lives outside the unit's cgroup.
- **Impact:** a guest-wide OOM can kill nginx, sshd or conmon, and the reaper may stop the guest mid-build.
- **Fix:** add podman `--memory` sized from memoryMiB, set ninja's `-j`, and delete the dead OOMPolicy line.

### 32. Three non-ballooned 2.5 GiB workers plus a 4 GiB manager for one enabled app
- **Severity:** medium (operations)
- **Where:** src/apps/swarm.nix:29-36
- **Evidence:** 7.5 GiB the balloon cannot reclaim, about 24% of host RAM, for hello alone.
- **Impact:** the balloon squeezes the lab guests instead (entry 1).
- **Fix:** derive the worker count from the apps' reservations, with a minimum of 1.

### 33. sync.sh's switch has no time bound, and the NAS deploys in the same batch as its hard-mounted clients
- **Severity:** medium (tests-tooling)
- **Where:** sync.sh:200,321-324,514,574,658-680; nas.nix:11
- **Evidence:** the switch has no timeout or ServerAlive, the NAS deploys in parallel with its clients, and the mounts are `hard`.
- **Impact:** a hang blocks the sync while it holds the tfstate lock and the reaper pause.
- **Fix:** deploy the NAS first, wrap the switch in `timeout`, and set ServerAlive.

### 34. Removing an automount leaves a stale autofs mount: the ACME move broke edge TLS for 23 minutes
- **Severity:** medium (operations)
- **Where:** vm-200 and vm-100; traefik/default.nix:688-690,762; nas-clients.nix
- **Evidence:** tmpfiles skipped the stale autofs mount, and ACME failed with "host is down" until a reboot.
- **Impact:** the edge served the default certificate for 23 minutes, the switch did not converge, and the certificate was reissued.
- **Fix:** stop and unmount undeclared automounts during activation.

### 35. On-demand listen ports are positional, so adding one idle service renumbers the others
- **Severity:** medium (operations)
- **Where:** on-demand/default.nix:22,79-80
- **Evidence:** ports come from `imap0`, and a socket was left "not functional until restarted".
- **Impact:** an unrelated addition can kill a socket.
- **Fix:** derive ports from a stable key, such as portBase + vmid, or a port allocated per app.

### 36. minecraft-env truncates rcon.env on every start and keeps rcon secrets on the NAS share
- **Severity:** medium (secrets-data)
- **Where:** 208 main.nix:13-14,64-68,85,109,124
- **Evidence:** `echo > rcon.env` runs on every start, and the secret files sit on NFS.
- **Impact:** CF_API_KEY is lost on every start, and the secrets land in every snapshot.
- **Fix:** declare cf-api-key and render the files with sops.templates under /run.

### 37. swarm-volume-restore wipes the volume before it knows the archive is good
- **Severity:** medium (secrets-data)
- **Where:** swarm/default.nix:479-494
- **Evidence:** the delete runs before the extract.
- **Impact:** a bad archive leaves an empty volume.
- **Fix:** run `zstd -t`, extract to a sibling directory, then swap.

### 38. The state worker cannot reach the controller, so the nightly dump of an idle-stopped app fails
- **Severity:** medium. Platform; latent.
- **Where:** swarm/default.nix:140,464-477,689-690; flows.nix:146-149
- **Evidence:** no router rule allows controllerPort from apps, and curl from vm-250 times out.
- **Impact:** an idle app with dumps gets no backup on the nights it sleeps.
- **Fix:** build the waker list and the router rule from one list, and add a reachability law.

### 39. An app placed on an internal-zone guest cannot serve an external route
- **Severity:** medium. Platform; latent.
- **Where:** flows.nix:63-71,126-129; catalog.nix:132; apps-catalog:191-201; traefik:844
- **Evidence:** app routes have vmid null, and the edge rule targets only the apps zone.
- **Impact:** placement and exposure do not compose.
- **Fix:** have flows target `catalog.clusters` nodes, and add a test.

### 40. Apps are coupled through global locks and one converge unit
- **Severity:** medium. Platform; merges three findings.
- **Where:** swarm/default.nix:125-133,205-221,327-351,609-650; on-demand:200; app-builder.py:573-604; app-builder.nix:41,91-94,197-203
- **Evidence:**
  - A wake is a full stack deploy under the global lock.
  - Converge redeploys every app on any catalog change and fails if any one app fails.
  - The builder holds one lock over all apps.
- **Impact:** one app delays or fails the others, which breaks Addenda 2 and 4.
- **Fix:** make wake and sleep a plain scale, run one converge unit per app, and use per-app builder locks.

### 41. Proxmox host configuration has two imperative owners and never converges
- **Severity:** medium. Tests-tooling; merges low findings from primitives and operations.
- **Where:** pve-install.sh:113-150; init.sh:189-233; sync.sh:85-86,404-480
- **Evidence:**
  - Every rerun of the interactive init rotates all tokens.
  - sync.sh pushes host state with 12 `|| echo WARNING` fallbacks.
  - Live drift: wake pools, a wake token and vmbr150 are still there.
  - Unused swarm kernel modules are loaded.
- **Impact:** wake breaks after a rerun, leftovers pile up, and failures exit 0.
- **Fix:** add one idempotent converge step run by sync. Per-guest settings should fail the deploy. Drop ip_vs, ip_vs_rr and vxlan.

### 42. About 100 embedded shell scripts skip shellcheck although the check claims every script
- **Severity:** medium (tests-tooling)
- **Where:** tests/shellcheck.nix:1-3
- **Evidence:** 45 writeShellScript, 60 `script = ''` blocks and 4 writeShellApplication; the check scans only *.sh files.
- **Impact:** most of the shell that runs as root is never linted.
- **Fix:** use writeShellApplication, or walk the systemd scripts through shellcheck.

### 43. Only the network laws have positive controls
- **Severity:** medium (tests-tooling)
- **Where:** tests/policy-network-controls.nix:9-13; tests/policy/*.nix
- **Evidence:** placement, secrets, apps, guests, ports and sso are never shown to fire.
- **Impact:** a regex that matches nothing passes forever.
- **Fix:** shared facts plus a table of controls for each law.

### 44. router-zones' DHCP check hard-codes the old pool start and cannot catch the overlap it exists for
- **Severity:** medium (tests-tooling)
- **Where:** router-zones.nix:215; zones.json; tests/lib/lab.nix:42
- **Evidence:** the test asserts 211-254 while the pool is 250-254, and the vlans are restated.
- **Impact:** the overlap property is unchecked.
- **Fix:** read the bounds from net.zones.

### 45. Network grants have four representations; main.nix files hard-code vmids
- **Severity:** medium (primitives)
- **Where:** 110 main.nix:8,64; 112 main.nix:17,166; servarr.nix:7,115-117; lldap.nix:225-228; 105 main.nix:1589-1601; swarm/default.nix:162; off.guard in 128, 134, 136, 138
- **Evidence:** portSources and extraSources are written by hand, and only `grants` and flows guards are collected.
- **Impact:** the lab-wide views miss these sources, renumbering leaves stale entries, and four backends stay open lab-wide.
- **Fix:** keep one grant primitive and make portSources internal to the network module.

### 46. The collector's main.nix is a 1607-line monolith that owns other instances' alerts
- **Severity:** medium. Primitives; also merges the latent WAL-G alert bug.
- **Where:** 105 main.nix:20-44,138,213-219,451-529,781-795,1285-1291
- **Evidence:** domain, guest ids and ports are restated, and other instances' alerts live here. WAL-G pages critical for every postgres app.
- **Impact:** adding an alert means editing vm-105, and the first postgres app without wal-g gets paged nightly.
- **Fix:** add an `alerts` and `probes` schema that the collector gathers, and move each rule to the guest that owns the metric.

### 47. The NAS client set is read from every host's evaluated config
- **Severity:** medium (primitives)
- **Where:** flake.nix:38-43; nas-clients.nix:10-18; flows.nix:43-46
- **Evidence:** router evaluation takes 6.7 s against 1.8 s for a normal host (about 3.6x), and the collector's header promises the opposite.
- **Impact:** any broken main.nix also breaks the router and NAS evaluations.
- **Fix:** declare shares in instance.nix and collect them into `lab.nasClients`.

### 48. Hosts do not receive their own instance record, so main.nix restates hostName, guards and zone
- **Severity:** medium (primitives)
- **Where:** 21 main.nix files; nine ingressOnly lines; three regex parsers
- **Evidence:** flake.nix and network.nix already set these values.
- **Impact:** copying a folder to a new vmid needs literal edits.
- **Fix:** pass `instance` as a specialArg and delete the duplicates.

### 49. Apps have three representations, and the typed catalog is rebuilt on every host
- **Severity:** medium. Primitives; merges instances' lab.export finding.
- **Where:** lab/default.nix:111-127,203-207; secrets.nix:43-54; apps-catalog:232-245; base:25; lab-export.nix:28-40; policy-eval.nix:18
- **Evidence:** untyped `or` reads, a test-hook option, a per-host recompute and a private evalModules.
- **Impact:** defaults are duplicated, the catalog is evaluated about 35 times, and the copies can drift.
- **Fix:** type the catalog once in lab and pass it to every host.

### 50. Inventory `enabled` is a stringly tri-state re-encoding vm.power and idle.stopAfter
- **Severity:** medium. Primitives; merges instances' and tests-tooling's low findings.
- **Where:** lab/default.nix:153-163, plus about 14 consumer files, terraform, sync.sh and lab-export
- **Evidence:** the string is "false", "onDemand" or "true", and `cooldown` is a third name for idle.stopAfter. Nothing checks lab.json's shape.
- **Impact:** a typo compares false silently, and different consumers treat idle guests differently.
- **Fix:** export `power` and `idle` (or derived booleans) instead, and add a shape check.

### 51. The swarm is described twice: clusters, worker sets, secret-ref parsing and guard grants
- **Severity:** medium (platform)
- **Where:** catalog.nix:63,73,105-115,226; swarm/default.nix:162,177-189,225-226,588-594; service.nix:174
- **Evidence:** two worker lists, two secretRefs regexes and the literal `inventory."103"`.
- **Impact:** admission and runtime can disagree.
- **Fix:** have swarm read `catalog.clusters`, and export the helpers once.

### 52. Workstation scripts and tests restate lab facts the collector already holds
- **Severity:** medium (tests-tooling)
- **Where:** setup-dns.sh:5-11; sync.sh:90,96,102; init.sh:28; pve-install.sh:15-16; hermes-skills.nix:9
- **Evidence:** router IP, domain, ingress and NAS ids, lldap settings and token ids are written as literals.
- **Impact:** a renumber needs edits the collector cannot see.
- **Fix:** read these from `nix eval .#lab.export`.

### 53. Secret generation has special cases outside its primitive, and the Proxmox CA is stored twice
- **Severity:** medium. Tests-tooling; merges operations' finding.
- **Where:** init.sh:158,173-174,230; secrets-sync.sh:134-147; shared.nix:19; on-demand:19; 100 main.nix:57; 103 main.nix:27-28
- **Evidence:** wireguard and base64 keys are generated in init.sh, and proxmox-ca lives both in sops and in site.json.
- **Impact:** rotation leaves those secrets empty, and the two CA copies can drift.
- **Fix:** add the secret kinds, and keep the CA in site.json only.

### 54. Dead migration code is still shipped after the migrations ran
- **Severity:** medium. Primitives; others rated it low. Also absorbs the dead proxmox_ssh_password key.
- **Where:**
  - secrets-migrate.sh
  - sops-encrypt.sh --age
  - secrets-sync.sh:71
  - base/default.nix:18-20
  - policy/secrets.nix:81-83
  - the migrate tests
  - README:141-143
  - lib/secrets.sh:14-15
  - 109 lab-tokens-migrate
  - 105 retiredRules
  - the tfvars key
- **Evidence:** the legacy files are gone, but the redirect branch remains.
- **Impact:** about 150 lines of dead code, and a trap: any src/host-secrets/<host>.json silently redirects that host's secrets.
- **Fix:** delete all of it, keeping the pve-install pool cleanup until one converge run has happened.

### 55. Line budget overshot: about 28.7k non-test lines against the 18.6k target
- **Severity:** medium (primitives)
- **Where:** apps/hello/lib/httpserver.h (2823 lines); archrepo-build.sh (1313); 105 main.nix (1607)
- **Evidence:** the RESTRUCTURE measurement command.
- **Impact:** a vendored header alone is 10% of the budget.
- **Fix:** fetch the header pinned by hash, apply entry 46, port archrepo-build to Python, and share the helpers.

### 56. Public DNS lists every internal service, and a raw wildcard points any name at the origin
- **Severity:** low (security)
- **Where:** 300 main.nix:105-114; traefik:510
- **Evidence:** attic, registry and backup resolve publicly, and a random name resolves to the house IP.
- **Impact:** the internal inventory can be enumerated, and the origin leaks for any name.
- **Fix:** publish only routes with internet on, and drop `*`.

### 57. "internal-only" at the edge admits any private source, including DMZ neighbours
- **Severity:** low (security)
- **Where:** traefik:435-438; net.nix:31
- **Evidence:** the allow-list is all of RFC1918, which includes 10.200.0.0/24.
- **Impact:** a compromised DMZ guest can reach internet-off routes.
- **Fix:** list the LAN, wireguard and internal subnets only.

### 58. The Prometheus read API is open to every house LAN device
- **Severity:** low (security)
- **Where:** 105 main.nix:1595-1598
- **Evidence:** port 9090 is open to the whole /24.
- **Impact:** anyone on the LAN can see occupancy patterns.
- **Fix:** allow the workstation (and the notebook) only.

### 59. CrowdSec shares visitor IPs with crowdsec.net undeclared and pulls unpinned hub rules
- **Severity:** low (security)
- **Where:** traefik:212-222,616-631
- **Evidence:** CAPI sharing and the console are on, and hub collections are fetched at start.
- **Impact:** visitor data leaves the house undeclared, and the rules are not reproducible.
- **Fix:** declare the CAPI choice, and vendor the collections pinned by hash.

### 60. Cloudflare sees deploy bearer tokens and browser telemetry, and adds NEL reporting
- **Severity:** low (platform)
- **Where:** 140 instance.nix:13-29; service.nix:27-28
- **Evidence:** the deploy and hello routes are served through Cloudflare, with NEL headers.
- **Impact:** a third party decrypts CI tokens and browser beacons.
- **Fix:** set `off.cloudflare` on the deploy route, turn off NEL, and document the telemetry path.

### 61. The homepage sends each visit to jsDelivr and Unsplash and hard-codes the house coordinates
- **Severity:** low (primitives, instances)
- **Where:** 103 main.nix:136-145,180-185,303
- **Evidence:** third-party favicon and background, literal latitude and longitude, and 328 health log lines per hour. NET_RAW is needed by the ping cards.
- **Impact:** visitor IPs leak to third parties, the location is a literal, and the logs are noisy.
- **Fix:** serve the assets from the store, add the coordinates to site.json, and disable the image healthcheck.

### 62. The public IP is polled three times, and all DNS forwards to Cloudflare and Quad9
- **Severity:** low (security)
- **Where:** ddns-cloudflare.sh:26,36; crowdsec-home-whitelist.sh:14-23; 300 main.nix:122-124,451-457
- **Evidence:** three ipify pollers run every 5 min, and DNS goes over DoT to the two upstreams.
- **Impact:** one fact is held three times, and extra third-party calls go out.
- **Fix:** learn the address once on the router and publish it; consider unbound.

### 63. The public repo publishes device identities, and sync.sh stages every untracked file under src
- **Severity:** low (tests-tooling)
- **Where:** generated/site.json; sync.sh:595,686-697
- **Evidence:** MACs and a disk serial are committed, and sync runs `git add -A src`.
- **Impact:** a stray file under src gets published.
- **Fix:** keep personal fields private, and stage only declared paths.

### 64. path: evaluations copy the terraform working state world-readable into /nix/store
- **Severity:** low (tests-tooling)
- **Where:** terraform/main.tf:14-16; generated/terraform/
- **Evidence:** 43 copies in the store at mode 444, and the backups are 0644.
- **Impact:** anything the state ever holds leaks to local users.
- **Fix:** keep the working state outside the flake tree, and chmod the backups.

### 65. Secrets briefly on argv
- **Severity:** low (security)
- **Where:** lldap.nix:52; traefik:683
- **Evidence:** `--token "$TOKEN"` and `-k "$KEY"`.
- **Impact:** briefly visible in /proc.
- **Fix:** pass them through stdin, env or a file.

### 66. The workers' promtail runs in the docker group while parsing untrusted app output
- **Severity:** low (platform)
- **Where:** app-telemetry.nix:111-115
- **Evidence:** the docker group gives full socket access.
- **Impact:** a parser bug becomes root on the worker.
- **Fix:** put a read-only socket proxy in front.

### 67. An anonymous read-write `#` MQTT broker runs on vm-125 with no client
- **Severity:** low (instances)
- **Where:** 125 main.nix:13-14,198-208
- **Evidence:** anonymous with `readwrite #`, no mqtt config entry and no connections.
- **Impact:** a dead service with a small attack surface.
- **Fix:** delete it until a client exists.

### 68. Pushing a rotated host age key drops the old identity before the switch succeeds
- **Severity:** low (secrets-data)
- **Where:** sync.sh:279-288,305-307
- **Evidence:** the `mv` happens before the copy and switch.
- **Impact:** after a failed deploy, the next boot cannot decrypt.
- **Fix:** keep both identities until the switch succeeds.

### 69. Orphaned data from earlier layouts on the NAS and ingresses, including old ACME keys
- **Severity:** low (secrets-data, operations)
- **Where:** vm-109 `/srv/nas/data/{traefik-acme-*,crowdsec-*,forgejo-runner,homepage-tokens,qbittorrent-incomplete}` and the old db-dumps dirs; the old acme.json files on 100 and 200
- **Evidence:** nothing references them, and they are 0777.
- **Impact:** old keys travel in every snapshot.
- **Fix:** list them for the owner to delete by hand, and have the NAS module own its data tree.

### 70. Forgejo pre-upgrade DB copies accumulate forever
- **Severity:** low (instances)
- **Where:** 115 main.nix:88-111
- **Evidence:** `gitea.db.before-15.0.9`, with no pruning.
- **Impact:** one full DB copy per upgrade.
- **Fix:** keep only the newest copy, at mode 0600.

### 71. The archrepo completeness gate freezes official updates once a served name loses its source
- **Severity:** low (instances)
- **Where:** archrepo-build.sh:56-64,1083-1091
- **Evidence:** held back since 10-05 over six deleted AUR names. An alert exists, and the trade-off is documented.
- **Impact:** core security fixes stall.
- **Fix:** optionally publish the official closure anyway, or put a time bound on the alert.

### 72. Build parallelism is the core count (4) while appbuild is capped at 3G
- **Severity:** low (platform)
- **Where:** app-builder.nix:79,165
- **Evidence:** cores = 4, memoryMax = 3G.
- **Impact:** possible OOM followed by backoff.
- **Fix:** use min(cores, memory / per-build estimate).

### 73. The controller writes the rate-limit stamp before starting the unit
- **Severity:** low (platform)
- **Where:** controller-api.py:65-71,103-104
- **Evidence:** the stamp is written before `start_unit`, whose error is uncaught.
- **Impact:** an empty reply, then a 429.
- **Fix:** start first, write the stamp on success, and return 503 on failure.

### 74. A CI redeploy forces a full run that skips the unchanged check and the backoff
- **Severity:** low (platform)
- **Where:** swarm/default.nix:106; app-builder.py:542-561,581-582
- **Evidence:** `forced = only == app`, against Addendum 11.
- **Impact:** a deploy round each minute, and a failing commit is retried without backoff.
- **Fix:** the endpoint runs the normal check, and `--force` stays manual.

### 75. Editing an app's dashboards or build settings waits for a commit or the 30-minute poll
- **Severity:** low (platform)
- **Where:** app-builder.nix:69,84,209-212
- **Evidence:** dashboards are not in buildInputsOf, and the unit has no trigger.
- **Impact:** contradicts the README.
- **Fix:** add dashboards to the build inputs, and trigger on catalog changes.

### 76. One failed deploy sends two Telegram alerts naming vm-140
- **Severity:** low (platform)
- **Where:** 105 main.nix:719-739
- **Evidence:** two rules fire for the same fact.
- **Impact:** noise, and the wrong host for guest clusters.
- **Fix:** gate one rule on the other, and name the manager from the catalog.

### 77. Powered-off guests are scraped forever, and the down alert excludes them by regex
- **Severity:** low (operations)
- **Where:** 105 main.nix:91-95
- **Evidence:** two targets are permanently down, and there is a hand-built regex exclusion.
- **Impact:** a guest that fails to wake never alerts.
- **Fix:** skip powered-off targets, label idle ones, and alert on failed wakes.

### 78. After deinit.sh, TF_STATE_FRESH is ignored while the local state copy exists
- **Severity:** low (tests-tooling)
- **Where:** sync.sh:523-533; deinit.sh
- **Evidence:** the fresh flag applies only when no local state file exists.
- **Impact:** the documented recovery errors out.
- **Fix:** have deinit move the state aside, and have the flag back up and ignore any local copy.

### 79. VM tests have no per-test time bound
- **Severity:** low (tests-tooling)
- **Where:** tests/lib/lab.nix
- **Evidence:** no globalTimeout, and one test once ran 5423 s.
- **Impact:** a hang costs at least an hour.
- **Fix:** a named globalTimeout of about 3x the slowest run.

### 80. router-zones leak captures can pass vacuously
- **Severity:** low (tests-tooling)
- **Where:** router-zones.nix:220-249
- **Evidence:** tcpdump readiness is `sleep 1`, with no positive control inside the capture.
- **Impact:** the privacy tests can pass without seeing any traffic.
- **Fix:** wait for "listening on", and send one packet that must be seen.

### 81. secrets-check fails and shellcheck silently skips sync.sh under path: evaluation
- **Severity:** low (tests-tooling)
- **Where:** tests/secrets-check.nix:8-15; tests/shellcheck.nix:11-33
- **Evidence:** a fileset error in one check, while the other prints "scripts clean".
- **Impact:** two checks behave differently.
- **Fix:** one rule: move sync.sh under src, or fail loudly.

### 82. The "adding is one folder" workflow is untested
- **Severity:** low (tests-tooling)
- **Where:** instances/_template, apps/_template; modules/lab/tests
- **Evidence:** no test uses the templates.
- **Impact:** template rot goes unnoticed.
- **Fix:** a lab-test case that copies each template.

### 83. The podman healthcheck switch-failure filter exists twice with different regexes
- **Severity:** low (tests-tooling)
- **Where:** sync.sh:325-333; 207 tests/share.nix:72-77
- **Evidence:** `{1,16}` in one, `+` in the other.
- **Impact:** a duplicated hack.
- **Fix:** fix it at the source, or define the pattern once.

### 84. The OSSEC install guard keys on a directory and never retries a half install
- **Severity:** low (tests-tooling)
- **Where:** pve-install.sh:278
- **Evidence:** `[ ! -d /var/ossec ]`.
- **Impact:** a failed install blocks every retry.
- **Fix:** guard on the binary, and install via a temp prefix.

### 85. stack.sh parses Nix source with regexes
- **Severity:** low (tests-tooling)
- **Where:** stack.sh:39-60
- **Evidence:** it greps instance-schema.nix.
- **Impact:** fragile.
- **Fix:** read from `nix eval .#lab.inventory`.

### 86. Dumps are zstd -19 compressed before kopia, defeating dedup
- **Severity:** low (secrets-data)
- **Where:** db-backup:71-73; swarm/default.nix:497-506
- **Evidence:** dumps are compressed before kopia, which compresses anyway, and the containers stay paused during the NFS write.
- **Impact:** small today; grows with volume size.
- **Fix:** write plain dumps, and archive locally first.

### 87. The ntfy desktop token is a hard-coded special case beside the generic dotfiles kind
- **Severity:** low (secrets-data)
- **Where:** secrets-sync.sh:12-13,60-61,164-176,293-302
- **Evidence:** a named lab-to-dotfiles copy beside the generic dotfiles-to-lab kind.
- **Impact:** two mechanisms for one relation.
- **Fix:** use `dotfiles:` in one direction.

### 88. The sccache probe is special-cased because the schema has no internal tcp service
- **Severity:** low (primitives)
- **Where:** 105 main.nix:1285-1291; 110 instance.nix:10-12
- **Evidence:** a hand-written probe and grant.
- **Impact:** one fact in two files.
- **Fix:** allow tcp with `publicPort = null`.

### 89. Service and route are conflated for instances; shared helpers are duplicated
- **Severity:** low (primitives)
- **Where:** instance-schema.nix:67-91; apps-catalog:27,58,180; service.nix:51,174; catalog.nix:226-242
- **Evidence:** serviceName and enabledOf are defined twice, and every instance service gets `kind = "vm"`.
- **Impact:** the same rules maintained twice.
- **Fix:** export the helpers once.

### 90. Roles have no primitive; consumers fall back to literals
- **Severity:** low. Primitives; overstated, the concrete literals are counted in entries 45, 46 and 51.
- **Where:** telemetry.nix:30; zones.json; apps/swarm.nix:15-20; flows.nix:52-59
- **Evidence:** different shapes for each role.
- **Impact:** moving a role means finding each spelling.
- **Fix:** an optional `lab.roles` with a uniqueness assert.

### 91. Duplicated constants outside their single definition
- **Severity:** low (primitives)
- **Where:** 105 instance.nix:29; net.nix:61-63; private-ranges.nix; the 100 and 200 grants; swarm:80; app-builder.nix:28; wat and nyangine app.nix
- **Evidence:** the Prometheus URL, a single-use port, a 10-line wrapper, textfileDir and domain literals.
- **Impact:** renumbering needs several edits.
- **Fix:** use the existing definitions and helpers.

### 92. One instance's test file tests two other instances' files
- **Severity:** low (instances)
- **Where:** 104 tests/feeds_test.py:3,291-292; tests/feeds.nix:13-23
- **Evidence:** it tests 125's jinja and 105's scripts.
- **Impact:** breaks the rule that a test lives with what it tests.
- **Fix:** move those cases, and make the placement law flag this.

### 93. Stale comments, dead exports and a deploy pipeline narrated in five places
- **Severity:** low (primitives, platform, instances)
- **Where:** telemetry, flows, swarm, lib.tf, energy, 105, 103, 125, app-builder, apps/swarm.nix, 134, 114, 208, catalog, net, service
- **Evidence:** references to files that no longer exist, swarm-150, the builder on vm-117, a wrong minecraft probe reason. Dead exports: nodeShapes, cidrContains, enabledOf.
- **Impact:** misleading comments, and the pipeline prose drifts.
- **Fix:** describe the pipeline once, then delete or fix the rest.

### 94. README gaps against reality
- **Severity:** low (tests-tooling)
- **Where:** README Layout and Deploy sections
- **Evidence:** the second init.sh run is missing, the privileged-LXC overrides and the router folder are not mentioned, and setup-dns hard-codes the house.
- **Impact:** a deploy from the docs misses steps.
- **Fix:** update after entry 41.

## Per-dimension coverage notes

**Primitives**
- Read in full: the collector, schemas, catalog, flows, network, secrets, telemetry and every instance.nix.
- Read in part: grafana, traefik, swarm, servarr, sync.sh and terraform.
- Ran: repo-wide greps, policy-eval (passes), eval stats, and read-only checks on vm-109.
- Not done: VM tests. The *arr env overrides should be checked against the pinned images before relying on them.

**Security**
- Read the network, traefik, swarm, controller, router, authelia/lldap, registry, NAS, grafana, hermes, runner and terraform code.
- Live read-only:
  - Proxmox firewall and realm
  - router nft rules
  - guards on 105, 109, 118 and 121
  - edge crowdsec
  - reach tests
  - DNS
- Not verified: workers 250-252, vm-100's internals, the fritzbox hairpin, NFS squash settings, headscale.

**Secrets-data**
- Read the secrets toolchain, local-state, db-backup, kopia, tokens, swarm volumes and the backups skill.
- Mapped every instance's state handling.
- Live read-only on about 13 guests.
- Not done: decrypting any secret, checking vm-208 (it was off), inspecting off-site contents.

**Platform**
- Read the full apps and swarm pipeline against Addenda 2-14.
- Live read-only on vm-140, the workers, the edge, and vm-250's reach to the controller.
- The checks pass.
- Moby's ingress filtering was checked and blocks cross-app traffic, so that suspicion was dropped.
- Not run: the app VM tests or live spoofing. The tcp/udp, placement and tenant findings come from code only.

**Instances**
- Reviewed archbuild in full, plus around a dozen other instances and a hack sweep.
- Not reviewed in depth: grafana main.nix, router, authelia, paperless, arr, headscale, swarm, registry, cache, searxng, minecraft.
- Live:
  - failed units are clean
  - the runner loop was found through a restart scan
  - the certificate SAN problem was reproduced
  - lab.json equals the eval
- Archbuild log publishing is unverified.

**Tests-tooling**
- All 52 checks classified.
- Every eval-only check passes except secrets-check under path:.
- Only the share VM test was rerun (107 s).
- Scripts read in full; shellcheck on the top-level scripts is clean; Proxmox read-only.
- Not reviewed: secrets-sync internals, hermes-secrets.sh, media-stack.sh.

**Operations**
- Live read-only on the Proxmox host (memory, balloon, swap, storage, LVM, pools, tokens, logs, mail, SMART), all reachable guests, Prometheus, grafana rules, notifiers, backup freshness, the reaper, ACME, DDNS, NAS exports and terraform state (no drift).
- Not checked: Loki volume, Tempo and Pyroscope, silences, the swarm nodes, restore tests, terraform plan.

**Leads I did not verify:**
- vm-100's access log shows public Cloudflare clients hitting router `proxmox` (401s), so the internal ingress may be reachable from the internet (relates to entry 56).
- Guests 206 and 207 have read-write NFS exports with no_root_squash.
- Someone else ran terraform and root ssh on the host at 04:24-04:27 during the review.

## Refuted claims

- **Privileged LXCs as a defect:** this is a documented, tracked user decision. Only a nit remains: derive `features` from the guest's needs.
- **ntfy prune deleted the owner's account:** already fixed in Generation 446. The prune enforces the declared account set, which is intended.
- **Grafana and lldap miss the Addendum 13 boundary:** these are documented single-user decisions; only stale RESTRUCTURE wording remains.
- **init.sh rerun hits root password drift:** key auth already works and a blank password is allowed, so there is no forced failure.
- **Thin space not reclaimed on vm-210:** fstrim runs weekly, the gap is churn between trims, and the pool is at 32%.
- **Partial refutations kept inside entries:**
  - grafana is not affected by the Remote-User bypass (5)
  - NET_RAW is used (61)
  - the WARNING count is 12, not 17 (41)
  - redis serves two instances (91)
  - catalog.nodes is used, and the vm-117 runner references are correct (93)
  - the eval cost is about 3.6x, not 10x (47)