# Features

This is an unreviewed AI generated summary of the lab's features.

Everything below comes from `./sync.nu` on a Proxmox host prepared by `src/scripts/init.nu`; nothing is set by hand on
a guest. README.md is the short start; this file says what the lab does, where each part lives, and holds the
runbooks.

- [Deploy and the sync CLI](#deploy-and-the-sync-cli)
- [Nushell everywhere](#nushell-everywhere)
- [Proxmox host](#proxmox-host)
- [Layout and adding things](#layout-and-adding-things)
- [Network and zones](#network-and-zones)
- [Ingress and protection](#ingress-and-protection)
- [Identity](#identity)
- [Scale to zero and on-demand](#scale-to-zero-and-on-demand)
- [Apps swarm and the deploy controller](#apps-swarm-and-the-deploy-controller)
- [Telemetry and alerts](#telemetry-and-alerts)
- [Storage, backups and off-site](#storage-backups-and-off-site)
- [Secrets](#secrets)
- [Recovery](#recovery)
- [Services](#services)
- [Tests and laws](#tests-and-laws)

## Deploy and the sync CLI

- `./sync.nu`: the one command; checks the staged tree for secrets, converges secrets and the Proxmox host, applies
  terraform, builds every guest, deploys them in parallel (`HOMELAB_PARALLEL`), pins each guest's ssh host key through
  Proxmox, writes `src/generated/lab.json` and commits `Generation: <n>`. `--dry-run` evaluates, builds and prints the
  plan, touching nothing. `./sync.nu <guest>...` deploys the named guests alone (vmid or name), `--skip-host` leaves
  the Proxmox host and terraform out; a partial run commits nothing. `terraform-law` and `policy-eval` gate every
  run: a broken law stops it before anything is applied. Logs in `~/.local/state/homelab/logs/`, the last 30 runs.
- A deploy copies the guest's closure first, then pushes the guest's own age key and switches in place; the payloads it
  runs on a guest (`src/scripts/lib/host-age-key.nu`, `src/scripts/lib/switch-failures.nu`) run under the nu of that
  closure, so a guest still on a generation without nu deploys too. A declared unit that failed in the switch fails
  that guest's deploy, a transient one does not. A disk terraform grew reboots the guest to expand its partition.
  Each deployed guest records its generation (`/var/lib/homelab/deployed-toplevel`); one running another
  (a hand-run switch, a rollback) raises "Host off its deployed generation".
- Deploys pause the on-demand reaper (`/run/ondemand-reaper-pause-until`), so no guest stops mid-deploy.
- Terraform state lives on the nas (`/srv/nas/terraform`) with a lock; sync.nu works on a copy in
  `~/.local/state/homelab/terraform/` (`$XDG_STATE_HOME`), where terraform's providers live too, since a `path:`
  evaluation copies the whole flake tree into the world-readable store (`src/scripts/lib/tfstate.nu`).
  `TF_STATE_FRESH=1` starts an empty lab: it sets any local copy aside (`terraform.tfstate.<time>.backup`), as
  `deinit.nu` does, and never pulls from or locks a nas. `TF_STATE_OFFLINE=1` applies from the copy while the nas is
  down.
- `src/scripts/init.nu <ip>` pins Proxmox's host key after a console check, asks the site, makes secrets and the
  golden image, converges the host; `--pin <ip>` re-pins alone, `--upgrade <ip>` runs apt's full-upgrade on the host
  and names the kernel a reboot starts. `src/scripts/deinit.nu [--yes] [proxmox-ip]` tears
  the lab down. `src/instances/preconfigured/113-internal-hermes/lib/hermes-secrets.nu` once sets hermes' ssh key,
  github app, api key and telegram bot.
- `src/scripts/stack.nu status | {apps|media|public} {on|off} [--apply]`: swaps a boot phase's guests in or out (the
  box cannot host all) by editing their `power` line.
- `src/generated/lab.json` (`src/modules/lab-export.nix`, which documents its schema): the desktop clients'
  interface, the guests, routes, infra cards, monitoring endpoints and the ntfy server with its topics, read by the
  bar's homelab widget and the ntfy notifier in the dotfiles. Rewritten every run (`nix eval --json ./src#lab.export`),
  public and secret-free; `schema` changes only when a key changes meaning or goes away.
- The workstation resolves `*.lsck0.dev` through the lab's dns by its dotfiles' networkmanager module.
- `nix develop ./src`: every tool pinned by `src/flake.lock`; the sops age key is the dotfiles' (`$DOTFILES`,
  `$DOTFILES_SECRETS`), unlocked with the YubiKey (`dot secrets unlock`) when locked.

## Nushell everywhere

- Every script file of the repo is nushell: `sync.nu`, `src/scripts/`, the guests' scripts (`writeNu`), the test
  scripts and the git hook. Shell stays only embedded in nix (unit bodies, `src/modules/upstream`'s run, which
  archbuild's container calls with bash) and in the few lines that install nu on the Proxmox host.
- The workstation runs the flake's nu (0.108); the guests have the same nu in `src/modules/base`.
- The Proxmox host gets a static nu 0.108, downloaded once per version and checked against its pinned sha256
  (`src/scripts/lib/proxmox.nu`); `src/scripts/pve-install.nu` and the bulk hookscript run under it.
- archbuild's Arch container installs nushell with pacman before the night's build (`112-internal-archbuild`).

## Proxmox host

- `src/scripts/pve-install.nu` converges the host on every `init.nu` and `sync.nu` run: apt sources, the zone bridges,
  gpu passthrough, power settings, openipmi off without a bmc, root's password (`proxmox-root-pass`) and ssh keys
  (`src/secrets/keys/`, keys only: sshd takes no password), the route to the lab's subnets through the router, the
  lab's api users and tokens (created once, never rotated; undeclared `@pve` users and every empty pool are removed),
  the lldap realm, the node's address and the api certificate naming it, the bulk storage and its hookscript, the
  host exporter with its textfile collectors (thin pools, the drives' thermal time, machine checks, pending apt
  upgrades, which watchdog is armed), smartd, OSSEC, and the journal upload to vm-103. While the package mirrors or
  github are down, what needs them waits for the next run; the rest still converges. `deinit.nu` runs its teardown.
- Autorecovery: a panic, an oops, a hung task or a soft or hard lockup reboots the host. watchdog-mux arms the
  chipset's `sp5100_tco` watchdog, which resets a hang that never panics, from the next host boot on; until then
  "Host watchdog not armed" fires, and `systemctl stop watchdog-mux && rmmod softdog && systemctl start watchdog-mux`
  on the host arms it now. Guests come back in their boot order, the router right after the nas; idling guests stay
  off until woken.
- The bulk storage (the hdd's lvm-thin pool, vm-104's media disk) stays disabled except while vm-104 starts or stops
  (its hookscript), and pvestatd runs with its own lvm config (`/etc/lvm-pvestatd`) that rejects the hdd, so nothing
  but the nas wakes the disk. A resize (a terraform `diskGiB` change of vm-104's bulk disk too), a snapshot or a backup
  of that disk needs it enabled by hand for the operation, as root on the host:

  ```sh
  pvesm set bulk --disable 0    # then the resize, snapshot or backup, or ./sync.nu with the disk change
  pvesm set bulk --disable 1    # spun down again; the next converge does it too while vm-104 runs
  ```

- Firewall (`src/terraform/lib.tf`, held by `src/tests/terraform-law.nix`): the datacenter firewall is on; every
  guest's nic may send only from its own address and mac (the router's are exempt), and the host drops input its rules
  do not name. The router leaves lab traffic to the host unmasqueraded and the host routes the lab back through it,
  so each guest is admitted by its own address: ssh from `lan.workstation`, `lan.notebook`, the owner's wireguard
  devices and hermes (vm-113), the api and web ui (8006) from the first three, the ingresses and the dashboard
  (vm-102), node exporter from vm-103, ping from the lan and the dashboard; Proxmox's implicit `management` ipset is
  emptied. In front of every guest Proxmox also holds the recovery path: ssh from the operators and the router's leg
  in the guest's zone (`sync.nu`'s bastion), node exporter from vm-103, anything else dropped and logged. `sync.nu`
  refuses to run from any other address and fails while the firewall does not enforce (`proxmox-firewall` active with
  every guest's spoofed-source drop loaded).
- Turning the firewall on the first time: check that `lan.workstation` and `lan.notebook` in `site.json` are the
  fritzbox's reserved addresses of the two machines; `./sync.nu` (it creates an ipset `ipfilter-net0` per guest but
  the router, the cluster rules, and last the datacenter options with `input_policy = "DROP"`; no guest is replaced);
  then check `pve-firewall status`, `https://<proxmox>:8006`, `ssh root@10.100.0.107 docker node ls`, an on-demand
  wake, and from the router `ping -c1 10.100.0.100`. A guest that cannot talk: compare its address with
  `pvesh get /nodes/<node>/qemu/<vmid>/firewall/ipset/ipfilter-net0`.
- Firewall rollback: `ssh root@<proxmox> pve-firewall stop` lifts every rule until the host reboots;
  `pvesh set /cluster/firewall/options --enable 0` keeps it off until the next `sync.nu`. Without ssh: the console.
- Login: the `lldap` realm binds to lldap over ldaps (vm-101, port 6360), verified against the guest's own
  certificate, which the host reads from inside the guest; it grants Administrator to the lldap group `admins` and asks
  for a TOTP code after the password. Until the guest has a certificate (the sync after its first deploy), the group
  administers nothing. Each realm user needs a key, set by root@pam before the deploy that turns TOTP on:

  ```sh
  head -c 20 /dev/urandom | base32                     # the key; add it to an authenticator app
  pveum user modify <user>@lldap --keys <base32 key>   # on the Proxmox host, as root
  ```

- root@pam is outside the realm and keeps its own password (`proxmox-root-pass` in `src/secrets/shared.sops.json`),
  the way back in at the console and the web ui, where it asks for TOTP or WebAuthn too (Datacenter, Two Factor;
  its recovery keys printed and kept offline). Over ssh root takes keys alone.

## Layout and adding things

- `src/instances/core/<vmid>-<zone>-<service>/`: the guests the lab needs (router, ingresses, authelia and lldap,
  homepage, grafana and telemetry, ntfy, nas, cache, registry, the swarm and deploy controller);
  `src/instances/preconfigured/` the third-party services; `src/instances/custom/<name>/` the owner's apps. A guest
  folder holds `main.nix`, `instance.nix` (vm shape, services, idle, grants, tokens, `on`, secrets), `lib/`, `tests/`,
  `skill.md` (hermes' skill about it), `secrets.sops.json`, its key (`age.pub`, `age.sops`) and a generated
  `secrets.shared.sops.json`; an app folder holds `app.nix` and its secrets.
- A guest is a vm, or an unprivileged lxc where nothing it `needs` asks for a vm (`src/modules/instance-schema.nix`);
  `vm.kind.<kind> = "<why>"` overrides that. No container is privileged (`src/tests/policy/guests.nix`).
- A guest: copy `preconfigured/_template`, a vmid in the zone's range, `git add`, sync. An app: copy `custom/_template`
  with a repo and a branch (`src/modules/apps-catalog`).
- Every file has one owner: what one instance uses lives in its folder, what two or more use is a module
  (`src/modules/<name>.nix` or `src/modules/<name>/` with `default.nix`, `lib/`, `tests/`), what the lab itself uses
  has its own folder. Tests and docs do not make a file shared (`src/tests/policy/placement.nix`).
- Features are off until named in `on`, mostly as profiles (`src/modules/profiles.nix`): `hardenedInternal`,
  `hardenedExternal`, `listed`, `observed`, `traced`, `vpnEgress`, `torEgress`, concatenated and
  `lib.subtractLists` where one does not fit. `src/modules/service.nix` lists the features and refuses combinations
  that cannot work (sso on the edge, the waf without crowdsec).
- Protection per path is a second route on the same host and port with its own `path` and `on`. A guest's firewall
  opens ssh, node-exporter and its services' ports; a shared module opening more (an ingress, a swarm node) or an
  egress exit needs its opening in the instance's own `on`.
- `ssoPaths = [ "/metrics" "/admin" ];` keeps prefixes of a public internal route behind authelia; the lab's own
  readers reach the backend port directly. The edge has no authelia: an app's metrics on an external route are denied
  there for everyone (`catalog.metricsBlocks`).
- The ingresses, authelia, lldap, the homepage, the prober and the router read every route from the catalog
  (`src/modules/catalog.nix`); a new service needs no edit elsewhere.

## Network and zones

- Zones: internal (1xx, staff only), external dmz (200-249), apps swarm workers (250 and up), the router on the house
  lan with a leg in each (`src/modules/net.nix`, `src/generated/zones.json`).
- vm-300 router: nat, the zone firewall rendered from `src/modules/flows.nix` (every flow carries its reason), dhcp,
  split-horizon dns, wireguard for the owner's devices (`src/instances/core/300-router/main.nix`).
- No zone reaches the house or another zone, the internal one included: each exception is a forward naming its guests
  and ports (hermes to Proxmox, the dashboard's frame cards, vm-103's scrapes). The house reaches the internal zone and
  the dmz. A guest's ssh answers the operators (the workstation, the notebook, wireguard, hermes) and its node
  exporter vm-103 alone (`recovery` in `src/modules/flows.nix`). The router counts every refusal between the networks
  by its source network (`homelab_forward_denied_packets_total`) and logs it as `fwd-deny <network>:`; one from the
  dmz or the apps zone raises "Zone crossing refused".
- Wildcard routes: `*.mc` answers every name one label below it, forwarded by port and resolved by the router's
  template (`src/modules/catalog.nix`).
- Egress classes: a guest's internet traffic through the vpn exit (`src/modules/egress-vpn.nix`) or tor, with a
  killswitch, transparent to the program; qbittorrent and searxng use the vpn. The exit moves to the next of its
  `servers` when its handshake is three minutes old; none answering raises "VPN exit unavailable".
- Proton's forwarded port renewed and handed to qbittorrent (`300-router/lib/protonvpn-port.nu`).
- Cloudflare ddns for the public names (`300-router/lib/ddns-cloudflare.nu`); the house's public address and ipv6
  prefix asked of the fritzbox over upnp, no third party, and served by dns (`300-router/lib/public-address.nu`).
- Onion services for routes with `onion = true`, served by the router's tor and the edge
  (`300-router/lib/onion-services.nix`, `src/scripts/lib/onion.nu`, addresses in `src/generated/onions.json`).
- `wol-pc` on the router wakes the owner's pc from the vpn.
- Headscale tailnet control with Headplane (`140-internal-headscale`).
- `curl https://<host>.lsck0.dev | sh` bootstraps an Arch install from the dotfiles (`src/modules/install-hosts.nix`).

## Ingress and protection

- vm-100 internal traefik: tls, forwardauth, the wake of sleeping internal guests, the relay target of the edge.
  vm-200 edge traefik: the only host the internet reaches (`src/modules/traefik`).
- Real client address: `traefik-clientip` trusts only the lab's proxies and the pinned cloudflare ranges
  (`src/modules/traefik/lib/traefik-clientip`, `src/modules/net.nix` cloudflareRanges).
- crowdsec with an escalation ladder: captcha first, then bans of minutes, hours, a day (`traefik/lib/ladder.nix`);
  the waf through crowdsec's appsec. Brute force and the waf are banned at once.
- Scanners are deceived, then banned: path traversal and the honeypot get a `deceive` decision for five minutes and
  the day's ban in the same alert, which takes over when the deceive ends, whether the scanner stops or not. A forged
  search crawler and crowdsec's sensitive-files scenario, which a user agent switcher or an app serving `.bak` or
  `.exe` files can trip, get the deceive and a 15 minute ban; one seen again is banned for the day
  (`traefik/lib/ladder.nix`, `crowdsecBouncer.deceiveWindow`). What a browser or a shared address can trip (crowdsec's
  probing and crawl scenarios, the labyrinth) starts at a short ban or the captcha, never at a day's ban.
- The deception (`traefik/lib/gate/deception.go`): a deceived client gets 200s, small plausible fakes for `.env`,
  `.git/config`, wp-login and wp-admin, phpinfo, `/admin`, `*.zip` backups, server-status and `/api/*`, and the
  labyrinth for any other path, all trickled within the tarpit's slots. The honeypot's paths deceive a scanner hitting
  the house address directly too, which every other route refuses past cloudflare. Every fake carries canaries (an aws
  key, a database url, api and git tokens) drawn from the client and the path under a gate-only key
  (`lab-gate-canary-key`), so nobody else can compute them; each issuance is logged to the journal (`deception
  canary`, its id, client, path and values), so a later use names who fetched it where. Nothing in a fake comes from
  the lab. traefik's errors middlewares turn the gate's unassigned 452 and 453 into the fetch, and the deception
  checks the reason again, so no other visitor ever gets one: a backend answering 452 or 453 itself shows a logged bad
  gateway and trips no signal, since `forged-crawler` also requires the deception's own `X-Lab-Gate: forged-crawler`.
- lab-gate: crowdsec's decisions as readable pages, its own captcha, a token bucket for anonymous clients, the
  tarpit, the deception; onion visitors get an anti-phishing captcha (`traefik/lib/gate`, Go). Counters for grafana:
  `homelab_gate_deceives_total`, `homelab_gate_deceptions_total`, `homelab_gate_canaries_total`; routine scanning
  pages nobody.
- Bot defence: anubis on public routes, iocaine's labyrinth for crawlers, a disallow-all robots.txt and llms.txt
  (`src/modules/traefik/default.nix`). An `indexable` route's host serves its backend's robots.txt instead. On every
  route with `botDefense`, a request naming a search crawler (Googlebot, bingbot, Applebot, YandexBot, Baiduspider:
  `searchCrawlers` with `reverseDomains`) from neither its published ranges nor an address with forward-confirmed
  reverse dns in its domains gets the deception and crowdsec's `forged-crawler` decision; a crawler publishing a list
  alone (DuckDuckBot, Kagibot and others) is never called forged on a stale list, anubis challenges its name from
  elsewhere. A forger crowdsec already bans gets the ban page; verified crawlers pass as before.
- Per route: rate and in-flight limits, body limit, secure headers, access log, `houseUnlimited` for the house, a
  `guard` on the backend port, cloudflare's proxy with the origin refusing anyone else (`src/modules/service.nix`).
- The sso session reaches authelia and its portal alone: the gate strips `authelia_session` from every other route's
  cookies (`strip-session-cookie`), so no app or third-party backend sees it.
- A route whose guest is powered off answers 503 at once; no ingress dials it.
- Request budgets per app at the edge (`src/modules/limits`).

## Identity

- vm-101 authelia: forwardauth and the lab's oidc provider over lldap; `ssoPaths` put prefixes of a public route
  behind it (`101-internal-authelia`). A remembered login lasts a week.
- With a mail relay in `site.json` (`smtp = { host; port; username; sender; }`, its password the manual secret
  `smtp-password`) authelia mails enrolment codes and password resets; without one reset is off and codes land in
  `/var/lib/authelia-main/notification.txt` on vm-101.
- An app gets the lldap group `app-<route>`; forgejo, jellyfin and headscale log in through oidc (`oidc` in their
  instance.nix). `lab-user` on vm-101 manages people: `add`, `passwd`, `groups`, `ungroup`, `list`, and `offboard`,
  which deletes the user and its second factors and names the apps that keep an account of their own.
- Two dashboards: `homelab.lsck0.dev` for the admins, with the widgets and their tokens, and `start.lsck0.dev` for
  everyone else, links only.
- lldap's `admin` takes its password from `lldap-admin-password` at every start: rotate it with
  `sops unset src/instances/core/101-internal-authelia/secrets.sops.json '["lldap-admin-password"]'`, then `./sync.nu`.
- Proxmox logins through the lldap realm with TOTP (Proxmox host above).

## Scale to zero and on-demand

- `idle = { stopAfter; wakeAt; }` in instance.nix: the ingress's local proxy wakes a stopped guest through the Proxmox
  api on its first connection, holds it until the backend answers, and stops it after the idle time
  (`src/modules/on-demand`). Idle guests: archbuild, jellyseerr, navidrome, firefly, searxng (4h), privatebin, share.
- `wakeAt` wakes on a schedule: archbuild at 05:30 for the nightly build, after the nas' snapshot and off-site upload,
  firefly at 05:00 for the bank import.
- `power = "off"` keeps a guest stopped; `stack.nu` flips whole boot phases.
- Apps with `scaleToZero` run no task after `idle.stopAfter` (15 minutes unless set) and wake on the next request,
  held at the ingress until the health path answers (a few seconds). An app stays up without it when it has a job of
  its own (wat's backup loop), clients holding connections (websockets) or a tcp or udp route. A sleeping app keeps
  its `reservation`, since all may wake at once (`src/modules/swarm`).
- Minecraft: mc-gate answers server-list pings itself, so a sleeping server costs nothing, and wakes one server per
  real player login (`214-external-minecraft/lib/mc-gate`).

## Apps swarm and the deploy controller

- vm-107: the swarm manager and the app builder, rootless; builds every new commit, pushes to `registry.lsck0.dev`,
  deploys to the app's cluster, keeps the old version on failure, alerts and retries with backoff
  (`107-internal-swarm/lib/app-builder.py`). Editing an app's folder and syncing redeploys it without an app commit;
  disabling it removes its stack, its volumes stay on the state worker. A deploy of a sleeping app runs the new
  version until it is up, then puts it back to sleep.
- `app-builder-redeploy <app>` on vm-107, or from ci:
  `curl -fsS -X POST -H "Authorization: Bearer $DEPLOY_TOKEN" https://deploy.lsck0.dev/redeploy/<app>`, past any
  backoff; `GET /deploy/<app>` with the same token answers the live and previous commit, a hold and the last failure.
  `app-builder-rollback <app>` deploys the commit before the live one and holds it until a new commit lands.
- A deploy is undone when a new task fails its healthcheck or dies as it starts (`src/modules/swarm` swarm-deploy);
  one that converged but answers no `health` is the edge's "App has no healthy backend".
  `requireChecks = true` deploys a commit only once its GitHub check runs passed. Each app builds on empty BuildKit
  cache mounts, never on what another app's build left there.
- An app declares what only it knows: routes (host, path, service, port, `health`, a path answering below 500 when
  up), `metrics` endpoints, `stateful` services and `volumes`, `dumps` (a command and its `restore`, which
  `swarm-dump-restore <app> <dump> [<file>]` on the state worker runs), its features. Secrets reach a service as env
  (`env`) or as a file (`secretFiles`, for images reading `<KEY>_FILE`); a `manual` one is the owner's to set with
  sops, and the app does not deploy while it is empty. It owns its own authentication; the platform offers tls, bot
  defence, rate limits, telemetry, backups and scale to zero, each opted into.
- `watch = [ "<path>" ]` deploys only commits touching those paths; `schedule = "<systemd calendar>"` looks at the
  app on a timer instead of every poll, for a build too heavy for every push (a missed run runs at boot).
- Static sites (`static` in app.nix: a command, its output and its packages): built without network, served by one
  platform image (`107-internal-swarm/lib/static-site.nix`). An `indexable` route gets a generated robots.txt
  admitting every crawler and a sitemap.xml, unless the site ships its own.
- math.lsck0.dev (`src/instances/custom/math`): the owner's university notes from `lsck0/university`, built with
  texlive and nu as a static site daily at midnight (Europe/Berlin), only for commits touching `notes`, indexable by
  search engines.
- Workers are made from the apps' reservations, each app with its own overlay network, secrets, resource limits and
  telemetry tenant with one budget per app; one state worker holds the volumes (`src/instances/core/swarm.nix`,
  `src/modules/limits`). The registry's htpasswd auth has no per-repository rule, so every cluster can pull every
  app's images.
- vm-106 registry with offline gc and its ui.
- Grafana has a folder per app with its generated board `service-<app>` and the boards it ships
  (`dashboards = [ "<glob>" ]`). A browser frontend sends OpenTelemetry to its own origin:

  ```js
  // @opentelemetry/sdk-trace-web: spans to <app host>/otlp, traceparent on fetch to the app's own backend
  const provider = new WebTracerProvider({ resource: resourceFromAttributes({ "service.name": "web" }),
    spanProcessors: [new BatchSpanProcessor(new OTLPTraceExporter({ url: "/otlp/v1/traces" }))] });
  provider.register();
  registerInstrumentations({ instrumentations: [new FetchInstrumentation({ propagateTraceHeaderCorsUrls: [/.*/] })] });
  // web vitals: one histogram, browser.web_vital (ms), attribute web_vital.name
  ```

## Telemetry and alerts

- vm-103: prometheus, loki, tempo, pyroscope behind push doors that set the tenant by sender, grafana with the lab's
  boards and alerts (`103-internal-grafana`). Grafana opens on the homelab board; every user views, the `admins` group
  administers. The ingresses' request spans are in the Tempo source, each linked to its access log line and back.
- Journals ship to vm-103's journal-remote, the Proxmox host's too; node exporter and textfile collectors on every
  guest and the host (`src/modules/base`, `src/modules/textfile`). vm-103 scrapes each ingress's access log
  shipper, crowdsec and anubis, and authelia.
- The prober (blackbox) checks every `probe` route; the homepage shows its status.
- Alerts go to ntfy on vm-201, the critical ones to telegram too, each with its runbook and a link to the rule. Rules
  beyond the services' own: a unit failed for 15 minutes, an oom kill, a host off its deployed generation, a guard or
  the router refusing a connection, an ingress companion unreachable, the app builder stalled for two hours, and on
  the Proxmox host a reboot, an unclean end, machine checks, nvme heat, the watchdog unarmed and security upgrades
  pending for a week (`103-internal-grafana/lib/rules.nix`).
- Dead man's switch: vm-201 pings an off-site check (`deadman-ping-url`, e.g. healthchecks.io with a 5 minute period
  and 15 minutes grace, alerting by mail) on every heartbeat from vm-103. Until that url is set, or while the ping
  fails, "Dead man's switch unavailable" fires.
- Third-party outages are classified, not failures: `upstream.run` retries, then probes (`src/modules/upstream`).
- Energy: fronius exporter, spot prices and cost boards (`103-internal-grafana/lib`, `src/modules/energy`).

## Storage, backups and off-site

- vm-104 nas: nfs exports for the guests, syncthing, filebrowser (`104-internal-nas`). Every export checks subtrees,
  so a forged file handle cannot leave its share, and root is squashed where a share takes no root writes. smb and
  syncthing answer the owner's machines alone.
- The owner's machines mount the whole tree over smb, sealed: `//10.100.0.104/homelab` with
  `credentials=/etc/samba/homelab.cred,seal,vers=3.1.1`. That file is the dotfiles' secret `samba-homelab`
  (a `username=` line with the owner's login and a `password=` line, `openssl rand -hex 32`); secrets-sync.nu copies
  it to the nas, whose samba-user sets the password from it (`104-internal-nas/lib/samba.nix`). Changing the password
  is changing that file, then `./sync.nu`.
- Each disk's kopia repository holds the other disk's data (`lib/kopia.nix`): the nas repository on the hdd
  (`/srv/nas/bulk/BACKUPS/kopia`) snapshots the ssd's `/srv/nas` at 02:00 and verifies on Sundays, including a sample
  downloaded back from proton; the syncthing repository on the ssd (`/srv/nas/BACKUPS/kopia-syncthing`) snapshots the
  hdd's syncthing folders (not the machines' borg repos synced beside them) and cold storage at 03:00, and refuses to
  while the ssd's root is over 85% full.
  Moving the nas repository from its old place on the ssd, once (`kopia-init` refuses to start a second history
  beside it): `systemctl stop kopia-server`, `mv /srv/nas/BACKUPS/kopia /srv/nas/bulk/BACKUPS/kopia`,
  `systemctl restart kopia-init kopia-server` on vm-104.
- `proton-sync` mirrors the kopia repository to Proton Drive nightly at 04:00, one way, pruning before it uploads so a
  full drive frees itself (`lib/proton-mirror.nu`).
- Cold storage, for what must be kept but is rarely opened: `/srv/nas/bulk/cold-storage` on the hdd, smb share
  `cold-storage`. kopia-syncthing snapshots it nightly (monthly ones kept two years, yearly ones ten);
  `proton-cold-storage` uploads it to `/my-files/homelab-offsite/cold-storage` on Saturdays at 06:00, the first time
  15 minutes after the deploy that adds it, one way and deleting nothing there, so a file deleted here stays off-site
  (`lib/kopia.nix`, `upload` in `lib/proton-mirror.nu`). "Cold storage off-site copy stale" fires after 15 days
  without an upload, the backup alert on a stale snapshot.
- `proton-bisync` syncs the syncthing folder (`/srv/nas/syncthing/sync`) with `/my-files/homelab-offsite/sync` both
  ways hourly: what changes on the web or the phone reaches the nas and syncthing takes it to the devices. Its rules
  are in the header of `lib/proton-bisync.py`. Both run on Proton's drive cli and its session from
  `proton-drive-login` on vm-104 (`lib/kopia.nix`).
- Laying the bisync baseline, once, when the remote holds what it should (anything only one side holds is copied to
  the other): `ssh root@10.100.0.104 systemctl start --no-block proton-bisync-resync`, then
  `journalctl -fu proton-bisync-resync`. It reads every remote folder (about 7 hours for 13k folders), deletes nothing,
  keeps both sides of a differing file (the remote one as `<name>.proton-conflict.<ext>`), and resumes when cut short.
  Until then "Off-site copy stale" fires.
- After the baseline: local changes go up within the hour; a run reads remote folders for 40 minutes, longest unread
  first, so a remote change in a quiet folder can take half a day. A run that would delete over 20% of either side
  syncs nothing until `touch /var/lib/proton-bisync/allow-large; systemctl start proton-bisync`. A file deleted here
  goes to proton's trash; one deleted on proton waits a month in `/srv/nas/syncthing/proton-bisync-trash/<date>/`.
  Symlinks stay local.
- Databases dumped before the snapshot (`src/modules/db-backup`); sqlite apps run on local disk with a nas copy
  (`src/modules/local-state`); `nas-restore` puts a snapshot back in place.
- A full official Arch mirror on the nas's ssd root (`/srv/nas/archmirror`), synced hourly (`lib/archmirror-sync.nu`),
  beside the lsck0 repo (`/srv/nas/archrepo`).

## Secrets

- sops with a per-guest age key; each secret lives next to what reads it (`src/modules/secrets.nix` holds the
  layout): one guest's in its `instance.nix` and `secrets.sops.json`, an app's in its `app.nix`, a shared one in
  `src/secrets/shared.nix` and `src/secrets/shared.sops.json`, of which every reader gets its own generated copy.
  Each file is encrypted to the admins of `src/secrets/admins.txt` and the guests that read it.
- `src/scripts/secrets-sync.nu [--apply [--prune]]` (run by every sync) generates missing values by kind, copies
  dotfiles secrets, writes `.sops.yaml` and hands each guest only its own key. Adding one: read it in a config
  (`sops.secrets.<name>`), declare it with its kind (`src/secrets/shared.nix` lists the kinds), `./sync.nu`; a
  `manual` one is added empty, fill it with `sops <its file>`. Moving a declaration moves the value.
- A declared secret missing from its file stops its guest's build, so a new `manual` one is filled before its guest
  deploys: `secrets-sync.nu --apply`, then `sops <its file>`.
- A `guardsData:` secret (a key stored data or logins depend on) is never generated once the lab is deployed: a
  missing one stops the run until restored, or `--generate-guarded` for one that guards nothing yet.
- Plaintext never touches the repo: `src/scripts/sops-encrypt.nu` writes sops files; the pre-commit hook (`.githooks`,
  set by `init.nu` and `sync.nu`) refuses a staged plaintext sops file, key material or secret value
  (`src/scripts/secrets-check.nu`). The admin key never leaves the workstation, hermes included.
- Every ssh host key is pinned in `src/generated/known_hosts`: Proxmox's by `init.nu` after a console check, each
  guest's by `sync.nu` through Proxmox from inside the guest. Any other key stops the run.
- Rotating the admin key, whenever it may have leaked (it re-encrypts every file and renews every host key), inside
  `nix develop ./src` with the dotfiles unlocked:
  1. `age-keygen -o ~/projects/arch-dotfiles/secrets/age.new.txt`; it prints the new public key.
  2. Add it as a new line of `src/secrets/admins.txt`, keep the old line.
  3. `src/scripts/secrets-sync.nu --apply`: every file is re-encrypted to old and new key.
  4. Delete the old line, then
     `SOPS_AGE_KEY_FILE=~/projects/arch-dotfiles/secrets/age.new.txt src/scripts/secrets-sync.nu --apply`: every file
     is re-encrypted without the old key and every host gets a new key. It refuses to run unlocked by a key it would
     lock out.
  5. In the dotfiles, replace `age.txt` with `age.new.txt` and commit there; drop other copies
     (`~/.config/sops/age/keys.txt`).
  6. Change every secret value, since the old key reads them in history. First the two that guard stored data:
     `kopia-password` with `kopia-nas repository change-password` on vm-104, `authelia-storage-key` with
     `authelia storage encryption change-key` on vm-101. Generated ones: delete the line with `sops <its file>`, then
     `secrets-sync.nu --apply` (a `guardsData:` one with `--generate-guarded`). `dotfiles:` ones in the dotfiles'
     secrets. External ones (cloudflare, github, telegram, proton, trmnl): issue new, revoke old,
     `sops <its file>`.
  7. `./sync.nu`: it pushes the new host keys, re-activates each guest and commits.

## Recovery

- A guest lost its age key or the file is broken: `./sync.nu` rewrites it and re-activates the guest. A host key to
  renew: delete the guest's `age.sops` and `age.pub`, then `./sync.nu`.
- A guest was recreated: `sync.nu` reads its new ssh host key through Proxmox. Proxmox reinstalled:
  `src/scripts/init.nu --pin <proxmox-ip>` after comparing the fingerprint on its console.
- A service's data is broken: `ssh root@10.100.0.104 nas-restore service <share> <snapshot id or date> --yes` restores
  `/srv/nas/data/<share>` in place. A service with `homelab.localState` takes it at its next start; nas-restore prints
  the guest and the command that makes it take it now.
- The lab is gone, the nas with it: sign in to proton (`proton-username`, `proton-password` of
  `src/instances/core/104-internal-nas/secrets.sops.json`, the second factor from `proton-totp-secret` of
  `src/secrets/shared.sops.json`; `proton-drive auth login`), then
  `proton-drive filesystem download /my-files/homelab-offsite/BACKUPS/kopia <dir>`,
  `kopia repository connect filesystem --path <dir>` with `kopia-password` from the nas's secrets, and
  `kopia snapshot list` / `kopia restore <snapshot> <target>`. The syncthing folder is not in kopia: its copy is
  `/my-files/homelab-offsite/sync`, with proton's file revisions and trash as its history.
- The nas is down: `TF_STATE_OFFLINE=1 ./sync.nu` applies from the local state copy.
- The Proxmox firewall locks out a machine: ssh stays open to `lan.workstation` and `lan.notebook`, so
  `ssh root@<proxmox> pve-firewall stop` from either (or the host's console); fix `lan.workstation`/`lan.notebook` in
  `site.json`, then `./sync.nu` turns it on again.

## Services

- vm-105 cache: redis for the ci's sccache.
- vm-102 homepage: cards for every service and app, generated from their `homepage` data; a powered-off guest's card
  links nowhere.
- vm-110 forgejo: oidc logins, pull mirrors of every owned github repo (`lib/forgejo-mirror.nu`).
- vm-111 ci: github actions and forgejo runners, one rootless docker per trust level, never root.
- vm-112 archbuild: nightly signed builds of the lsck0 pacman repo in an Arch container, published to the nas and
  vm-210; a completeness gate holds back a night that would lose a package
  (`112-internal-archbuild/lib/archrepo-build.nu`, `lib/archrepo-list.nu`).
- vm-113 hermes: the owner's telegram agent, root on the lab, with skills and `lab-pr` for repo changes; a github app
  token per repo (`lib/github-app-token.nu`).
- vm-114 terminal: TRMNL e-ink feeds for calendar, lab stats, arxiv, energy and github.
- vm-120 qbittorrent through the vpn exit with a forwarded port.
- vm-121 arr: prowlarr (indexers through tor) with flaresolverr, radarr, sonarr, lidarr, bazarr, recyclarr, wired by
  `lib/arr-wire.nu`.
- vm-122 jellyfin with janitorr and ollama on the gpu; vm-123 seerr requests; vm-124 navidrome.
- vm-130 home assistant; vm-131 paperless-ngx with paperless-ai; vm-132 firefly iii with the fints importer;
  vm-133 huginn; vm-134 taskchampion sync server (ciphertext only).
- vm-210 public lsck0 pacman mirror at `mirror.lsck0.dev`, with the install iso vm-112 builds and signs nightly
  under `iso/`: each dated `archlinux-lsck0-<date>-x86_64.iso` with its `.sha256` and `.sig`,
  `archlinux-lsck0-latest-x86_64.iso` linking the newest, and `lsck0-signing.asc`, the key to verify against. It keeps
  the newest iso, the first of the week and the first of the month (`iso-prune` in `archrepo-build.nu`).
- vm-211 searxng through the vpn exit, with the limiter and link tokens, an image proxy and json for hermes. Engines:
  bing, startpage (google's ranking, weighted double), duckduckgo web, wikidata's infobox (1 s timeout, none on a slow
  query), nixos wiki, duden and searxng's defaults; brave and the duckduckgo html endpoint are off (captcha and 403 on
  the exit), the onion engines inactive. Wikipedia, the Arch and NixOS wikis, github and stackoverflow rank first,
  pinterest is removed. A page waits at most 2 s for an engine.
- vm-212 privatebin; vm-213 file share; vm-215 teamspeak 6.
- vm-214 minecraft at `<server>.mc.lsck0.dev`, one server awake at a time behind mc-gate: cobblemon (the owner's pack,
  1.21.1), vanilla (the newest release) and atm (All the Mons 1.3.0 on NeoForge, flight allowed). `mc-modpack`
  switches a server's pack, each pack keeping its own world. Every server takes extra mods beside its pack from
  `minecraft-modpacks/extra/<server>`, owned by the container's user at every start; `mc-mod add` reads a jar's
  metadata and refuses one whose loader or minecraft or neoforge range the server's version falls outside of
  (`214-external-minecraft`).
- Apps: hello (the ci demo, a static c server, also an onion route), math (above), nyangine (its web example), wat.

## Tests and laws

- Every `src/tests/<name>.nix` and every `tests/<name>.nix` of an instance or module is a flake check named by its
  file, a function of `{ pkgs, lib, inputs, specialArgs, ... }` returning a derivation:
  `nix build ./src#checks.x86_64-linux.<name>`. A new file needs `git add`.
- VM tests run the real modules on stand-in boundaries through `src/tests/lib/`: `lab.nix` makes the nodes (`guest`,
  `router`, `nas`, `multi`), `labprobe.py` checks reachability plans (every denial with a positive control),
  `http.py` makes requests through the ingresses; `offline-router.nix`, `offline-traefik.nix`, `pki.nix`,
  `secret-values.nix`, `images.nix` and `nas-mounts.nix` replace what lies outside the lab. Tests without
  `modules/base` import `src/tests/stubs.nix`.
- Seeded tests print `seed=<n>` and draw all randomness from it; failing seeds stay in `passthru.regressionSeeds`
  (`nix build ./src#legacyPackages.x86_64-linux.seeded.<name>.<seed>`).
- `policy-eval`: the lab's laws over every real configuration, one file per area in `src/tests/policy/` (antibot,
  apps, guests, images, mounts, network, placement, ports, secrets, sso, telemetry); the host memory budget is one.
- `nu-check` parses every nu script under the pinned nushell; `shellcheck` checks the shell embedded in nix;
  `terraform-law` holds the Proxmox firewall; `pve-install` runs the host converge with Proxmox's tools stubbed.
- Manual: `src/tests/media-stack.nu` (docker) and `113-internal-hermes/tests/hermes-agent.nu` (free nous model, or
  `ANTHROPIC_API_KEY`).
- No test reaches the internet: images and sources are fixed-output derivations.
