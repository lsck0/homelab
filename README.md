# Homelab

```sh
git clone https://github.com/lsck0/homelab
cd homelab
nix develop ./src
```

Nix with flakes is the one thing to install: every tool comes from the flake's dev shell, pinned by `src/flake.lock`
(docker only for the e2e scripts). The sops age key is owned by the dotfiles repo at
`~/projects/arch-dotfiles/secrets/age.txt` (`$DOTFILES` moves the checkout); `secrets/age.txt` is a symlink to it that
`init.sh` and `sync.sh` keep pointing there, and `sync.sh` unlocks it with the YubiKey
(`~/projects/arch-dotfiles/scripts/yubikey.sh unlock`) when it is locked. Every key in `src/lab/keys/` is authorized on
every guest, the router and Proxmox root, so the deploying machine's `~/.ssh/id_ed25519.pub` must be one of them.

## Layout

Three planes:

1. Platform: `src/modules/`, what every deployment composes (network, ingress, identity, telemetry, storage,
   secrets, the swarm), and the platform's own instances (router, ingresses, authelia, grafana, nas, registry, the
   deploy controller).
2. Instances: `src/instances/<vmid>-<zone>-<service>/`, one folder per guest, in the internal zone (1xx, staff only,
   behind authelia) or the external zone (200-249, public, behind the edge).
3. Apps: `src/apps/<name>/`, one folder per app built from its own repo, run on the apps swarm (workers 250 and up)
   or on a guest of its own. Each app has its own overlay network, secrets, resource reservation, telemetry tenant
   and lldap group `app-<route>`. The registry's htpasswd auth has no per-repository rule, so every cluster can pull
   every app's images.

```
sync.sh                     deploy everything
src/
  flake.nix                 hosts, checks and the `lab` facts, all discovered from the folders below
  instances/<vmid>-<zone>-<service>/   (the router: instances/300-router/, no zone of its own)
    main.nix                the guest's nixos configuration
    instance.nix            what others need to know: vm shape, services (exposure, protection, card, oidc),
                            idle, grants, tokens, egress, secrets
    lib/                    what only this guest uses: its modules, scripts, templates, dashboards
    tests/  skill.md        its checks, and hermes' skill about it
    secrets.sops.json       its own secrets; age.pub and age.sops its key; secrets.shared.sops.json generated
  modules/                  the platform: what two or more guests use
    <name>.nix              a module of one file
    <name>/                 a module of more: default.nix, lib/ (its scripts and templates), tests/
  apps/swarm.nix            the swarm: manager, builder, worker count and shape
  apps/<name>/app.nix       an app: repo, branch and the same service properties; secrets.sops.json its secrets
  lab/keys/                 the ssh public keys authorized everywhere (hand-written)
  secrets/                  admins.txt (the admins' age recipients), shared.nix and shared.sops.json (the
                            secrets two or more guests read, or the operator alone)
  terraform/                main.tf, lib.tf: the guests from `nix eval .#lab.terraform`, the proxmox firewall; its
                            connection vars
  generated/                what the scripts write: site.json and known_hosts (init.sh, sync.sh), zones.json (the
                            zones, edited by hand too), lab.json (sync.sh, for desktop clients), nodes/<vmid>-apps-swarm/
                            (the workers' keys)
  scripts/                  the workstation's tools: init, deinit, pve-install (the proxmox host's converge and
                            teardown), secrets-*, sops-encrypt, stack, setup-dns
  tests/                    the harness (lib/, stubs/, policy/ the lab's laws) and the tests of the whole lab
```

Every file has one owner. What one instance alone uses (a module, a script, a template, a dashboard, a test) lives
in that instance's folder; what two or more instances use is a module; what the lab itself uses (the flake, the
workstation's scripts, terraform) has its own folder. Tests, laws and docs do not make a file shared: a test lives
with what it tests. `src/tests/policy/placement.nix` holds the tree to it.

Every property is on by default and turned off where it does not fit, with its reason: `off.<feature> = "<why>";`
(`src/modules/service.nix` lists the features).

### Adding an instance

Copy `src/instances/_template/` to `src/instances/<vmid>-<zone>-<service>/`, the vmid inside the zone's range, fill
in `main.nix` and `instance.nix`, `git add` it, then `./sync.sh`. Terraform creates the guest (a vm or an
unprivileged lxc, as `vm.needs` decides; `vm.kind.<kind> = "<why>"` overrides the rule, and `vm.privileged = true`
makes an internal lxc privileged for nfs mounts, which the containers pending migration to vms still use); the
ingress, authelia, the homepage, the prober and the router pick up its services. Nothing else is edited.

### Adding an app

Copy `src/apps/_template/` to `src/apps/<name>/`: a repo and a branch are enough. `git add` it, then `./sync.sh`. The
app is built from the repo's Dockerfile or compose file and answers at `<name>.lsck0.dev` behind the edge and
authelia; `routes`, `off`, `resources`, `placement` and the rest are in `src/modules/apps-catalog`.

The deploy controller vm-140 builds every new commit, parks the images in `registry.lsck0.dev` and deploys them to
the app's cluster. Editing an app's folder and syncing redeploys it without an app commit; disabling it removes its
stack (its volumes stay on the state worker). A failed build or deploy keeps the old version running, alerts, and is
retried with backoff or on the next commit. `app-builder-redeploy <app>` on vm-140 rebuilds one now; a ci job does it
with `curl -fsS -X POST -H "Authorization: Bearer $DEPLOY_TOKEN" https://deploy.lsck0.dev/redeploy/<app>`. An app with
`idle.stopAfter` stops after that long without traffic, and its first request wakes it; only over http: the router
forwards a tcp or udp route straight to its backend, past every wake proxy, so the catalog refuses `idle` there.

An app cannot take the lab down: it holds a `reservation` of the workers (checked at sync and at deploy), each task
its `resources` limits, each route a request budget at the edge, and its logs, traces, profiles and metrics their own
tenant with one budget per app (`src/modules/limits`). Grafana has a folder per app with its generated board
`service-<app>` and the boards it ships (`dashboards = [ "<glob>" ]`, taken from the deployed commit). A browser
frontend sends OpenTelemetry to its own origin:

```js
// @opentelemetry/sdk-trace-web: spans to <app host>/otlp, traceparent on fetch to the app's own backend
const provider = new WebTracerProvider({ resource: resourceFromAttributes({ "service.name": "web" }),
  spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url: "/otlp/v1/traces" }))] });
provider.register();
registerInstrumentations({ instrumentations: [new FetchInstrumentation({ propagateTraceHeaderCorsUrls: [/.*/] })] });
// web vitals: one histogram, browser.web_vital (ms), attribute web_vital.name
```

## Deploy

```sh
src/scripts/init.sh <proxmox-ip>      # once: pin proxmox's host key, site, secrets, golden image, the host's converge
src/instances/114-internal-hermes/lib/hermes-secrets.sh   # once: hermes' ssh key, github app, api key, telegram bot
TF_STATE_FRESH=1 ./sync.sh            # the first deploy: no terraform state on the nas yet
./sync.sh                             # every deploy after; the second one also sets up the lldap realm
TF_STATE_OFFLINE=1 ./sync.sh          # the nas is down: apply from the local state copy
src/scripts/stack.sh status           # which guest groups are on
src/scripts/stack.sh {apps|media|public} {on|off} [--apply]   # swap a group in or out (the box cannot host all)
sudo src/scripts/setup-dns.sh         # workstation: resolve *.<domain> through the router (reads generated/lab.json)
src/scripts/init.sh --pin <proxmox-ip>   # (re)pin proxmox's ssh host key
src/scripts/deinit.sh [--yes] [proxmox-ip]   # tear the lab down again
```

A sync, in order: the lab's facts (`nix eval .#lab.inventory`, `.#lab.export` into `generated/lab.json`); the
Proxmox host converged by `src/scripts/pve-install.sh` (packages, bridges, api users and tokens, the lldap realm, the
api certificate, monitoring; a rerun changes nothing, a token is never rotated, rerunning `init.sh` is safe); terraform
under the nas's state lock, released once the state is pushed; the firewall checked running; secrets synced
(`secrets-sync.sh`); every closure built at once; the router, then the nas alone (its clients hard-mount it), then
every other guest in parallel, each copy and switch bounded in time; the generation committed with the declared paths
only (tracked files and what the run generated, never a stray file under `src/`). Github unavailable: the run
compares with the last fetch and pushes the generation on the next sync.

The lldap realm pins the certificate lldap makes on vm-101 for its own address, read through the hypervisor (qemu
agent), so it waits for vm-101's first deploy: on a fresh lab, and after vm-101 is recreated, the next sync sets it.

### Proxmox firewall

Every guest but the router is bound to its own address and mac (`ipfilter-net0`, macfilter), and the host drops
what it does not name: ssh from the house lan, 8006 from `site.json` `lan.workstation` and `lan.router` (the lab
reaches the host masqueraded as the router: the ingresses' wake and proxmox route, the homepage, Hermes), 9100 from
the router, ping from the lan (`src/terraform/lib.tf` FIREWALL; the check `terraform-law` holds lib.tf to it,
`sync.sh` fails while `pve-firewall status` is not `enabled/running`). Terraform turns it on last, after the guests'
ipsets and the host rules exist.

Turning it on (the first sync of a lab where it was off):
1. `ip -4 route get <proxmox-ip>` on the workstation: its `src` must be `lan.workstation` in `src/generated/site.json`
   (a fritzbox address reservation keeps it); `lan.router` the router's address. A wrong one locks the api out.
2. Keep a way in that does not need 8006: the host's console, or an ssh session to it left open (ssh from the lan
   stays allowed, an open session survives the switch).
3. `./sync.sh`, then check: `ssh root@<proxmox-ip> pve-firewall status` says `enabled/running`; the web ui answers
   on the workstation and through `https://proxmox.<domain>`; from another lan device 8006 times out; an onDemand
   guest wakes; the homepage's proxmox card and the node exporter target in Prometheus are up.

Rolling back: `ssh root@<proxmox-ip> pve-firewall stop` (or on the console) stops all filtering at once, until the
next `pve-firewall start` or reboot; `pvesh set /cluster/firewall/options --enable 0` turns it off for good, until a
sync turns it on again. Fix the address in `site.json` (or the rule in lib.tf), then sync. A guest that cannot talk
after its address changed gets its ipset on the next sync.

### Proxmox login

The `lldap` realm syncs the lldap users hourly; `admins` gets Administrator. It binds over ldaps as the read-only
`proxmox-bind`, pinned to vm-101's certificate, and asks every realm user for a TOTP code. A realm user has none
until root sets it, on the host: `pveum realm sync lldap`, `oathkeygen` (prints a base32 secret), `pveum user modify
<user>@lldap --keys <secret>`, and the secret into the authenticator app
(`otpauth://totp/Proxmox:<user>?secret=<secret>`). `root@pam` with `proxmox-root-pass` stays the way in when lldap
is down. lldap's own `admin` has its own secret, `lldap-admin-password`, which lldap takes at every start: rotate it
with `sops unset src/instances/101-internal-authelia/secrets.sops.json '["lldap-admin-password"]'`,
`src/scripts/secrets-sync.sh --apply`, `./sync.sh`.

Desktop clients (the bar's homelab widget and the ntfy notifier in the owner's dotfiles) read
`src/generated/lab.json` and nothing else of this repo: the guests, the routes, the infra cards, the monitoring
endpoints and the ntfy server with its topics. `src/modules/lab-export.nix` defines it and documents its schema;
sync.sh rewrites it on every run (`nix eval --json ./src#lab.export`). It is public like the rest of the repo and holds
no secret; `schema` changes only when a key changes meaning or goes away.

## Secrets

A secret lives next to what reads it (`src/modules/secrets.nix` holds the layout). One a single guest reads is
declared in its `instance.nix` (`secrets.<name> = "<kind>";`) with its value in that folder's `secrets.sops.json`; an
app's in its `app.nix` and `apps/<name>/secrets.sops.json`; one two or more guests read in `src/secrets/shared.nix`
and `src/secrets/shared.sops.json`, of which every reader gets its own generated copy, `secrets.shared.sops.json`.
Every guest has its own age key in its folder (`age.pub`, and `age.sops` encrypted to the admins only); each file is
encrypted to the admin recipients of `src/secrets/admins.txt` and the guests that read it. `sync.sh` runs
`src/scripts/secrets-sync.sh --apply`, which writes keys, rules, missing values and copies, and hands each guest only
its own key. The admin key never leaves the workstation, Hermes included. Plaintext never touches the repo: write sops
files with `src/scripts/sops-encrypt.sh`; the pre-commit hook (`.githooks`, set by `init.sh` and `sync.sh`) refuses a
commit that holds a sops file unencrypted, key material, or any secret value (`src/scripts/secrets-check.sh` runs it
on the staged tree).

Adding a secret: read it in a config (`sops.secrets.<name>`), declare it with its kind (`src/secrets/shared.nix`
lists the kinds) in the reading guest's `instance.nix`, or in `src/secrets/shared.nix` when several read it, then
`./sync.sh`. A generated one appears by itself, a `manual` one is added empty: fill it with `sops <its file>`.
Moving a declaration moves the value. `src/scripts/secrets-sync.sh [--apply [--prune]]` runs the same step by hand.

Every ssh host key is pinned in `src/generated/known_hosts`: Proxmox's by `init.sh` after a console check, each
guest's by `sync.sh`, which reads it through Proxmox from inside the guest. Any other key stops the run.

### Rotating the admin key

The dotfiles key sat on every guest before per-host keys existed, and on Hermes after: rotate it once now, and
whenever it may have leaked. A rotation re-encrypts every file under new data keys and renews every host key, since
the old key still opens all of them in the public history. Inside `nix develop ./src`, with the dotfiles unlocked:

1. `age-keygen -o ~/projects/arch-dotfiles/secrets/age.new.txt`; it prints the new public key.
2. Add that public key as a new line of `src/secrets/admins.txt`, keep the old line.
3. `src/scripts/secrets-sync.sh --apply`: still unlocked by the old key, it re-encrypts every file to old and new key.
4. Delete the old key's line from `src/secrets/admins.txt`, then
   `SOPS_AGE_KEY_FILE=~/projects/arch-dotfiles/secrets/age.new.txt src/scripts/secrets-sync.sh --apply`: every file
   is re-encrypted without the old key and every host gets a new key. It refuses to run unlocked by a key it would
   lock out.
5. In the dotfiles repo, replace `age.txt` with `age.new.txt` and commit there; drop any other copy of the old key
   (`~/.config/sops/age/keys.txt`).
6. Change every secret value, since the old key reads them in history. Before anything else, change the two that
   guard stored data where they are used: `kopia-password` with `kopia-nas repository change-password` on vm-109,
   `authelia-storage-key` with `authelia storage encryption change-key` on vm-101. Generated ones: delete the line
   with `sops <its file>`, and `src/scripts/secrets-sync.sh --apply` makes a new one. External ones (cloudflare,
   github, telegram, attic, proton, trmnl tokens and keys): issue new ones at the provider, revoke the old, put the
   new ones in with `sops <its file>`.
7. `./sync.sh`: it pushes the new host keys, re-activates each guest with them, and commits.

### Recovery

- A guest lost its age key, or its key file is broken: `./sync.sh` rewrites it and re-activates the guest. A host
  key that must be renewed: delete the guest's `age.sops` and `age.pub`, then `./sync.sh`.
- A guest was recreated: `sync.sh` reads its new ssh host key through Proxmox. Proxmox reinstalled:
  `src/scripts/init.sh --pin <proxmox-ip>` after comparing the fingerprint on its console.
- The lab is gone, the nas with it: the off-site copy is the kopia repository on Proton Drive. Sign in with the
  proton account of `src/secrets/shared.sops.json` (`proton-drive auth login`), `proton-drive filesystem download
  /my-files/homelab-offsite/BACKUPS/kopia <dir>`, then `kopia repository connect filesystem --path <dir>` with
  `kopia-password` from `src/instances/109-internal-nas/secrets.sops.json`, and `kopia snapshot list` /
  `kopia restore <snapshot> <target>`.
- Terraform state: the nas holds it (`/srv/nas/terraform`), sync.sh works on a copy outside the repo,
  `~/.local/state/homelab/terraform/` (a `path:` evaluation would copy anything in the tree into the world-readable
  store); `TF_STATE_OFFLINE=1 ./sync.sh` applies from that copy while the nas is down, `TF_STATE_FRESH=1 ./sync.sh`
  starts an empty lab and sets any local copy aside (`deinit.sh` does too).

## Test

```sh
nix eval ./src#checks.x86_64-linux --apply builtins.attrNames                    # every check
nix build ./src#checks.x86_64-linux.<name> -L --no-link --max-jobs 1           # one check
nix build ./src#legacyPackages.x86_64-linux.seeded.<name>.<seed> -L --no-link   # one seed of a seeded test
src/tests/media-stack.sh                                  # media stack against the real containers (docker)
src/instances/114-internal-hermes/tests/hermes-agent.sh   # hermes scenarios (free nous model, or ANTHROPIC_API_KEY)
```

Every `src/tests/<name>.nix`, `src/instances/<folder>/tests/<name>.nix` and `src/modules/<name>/tests/<name>.nix` is
a check, named by its file: a function of
`{ pkgs, lib, inputs, specialArgs, ... }` (`specialArgs` are the hosts' own: lab, inventory, site, nasClients)
returning a derivation. A new file needs `git add`, since the flake sees tracked files only. A test that takes `seed`
prints `seed=<n>` first and draws all randomness from it; a seed that once failed goes into its
`passthru.regressionSeeds`, which the check reruns. No test reaches the internet: images and plugin sources are
fixed-output derivations, fetched once at build time.

VM tests run the lab's real modules on stand-in boundaries through `src/tests/lib/`; each file's header says how to
use it. `lab.nix` makes the nodes: `guest` (a lab host at its inventory address on the production stack, with its
instance file), `router` (the real router at its real NIC names), `nas` (exports exactly what the test's guests
mount), `multi` (one VM owning many addresses: a zone's probes, the internet, the house). `labprobe.py` with the
driver's `probe.py` checks reachability plans (every denial with a positive control), `http.py` makes requests
through the ingresses; `offline-router.nix`, `offline-traefik.nix`, `pki.nix`, `secret-values.nix`, `images.nix` and
`nas-mounts.nix` replace what lies outside the lab. Tests of one module without `modules/base` import
`src/tests/stubs.nix` instead. `policy-eval` checks the lab's laws over every real configuration at evaluation time:
each `src/tests/policy/<area>.nix` returns its violations, and the check lists them all.
