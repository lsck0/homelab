# Homelab Security & Performance Audit

Date: 2026-09-16. Method: static review of `src/` plus live probing of the
running lab from a LAN host (`192.168.178.138`) and public DNS. All testing was
against the owner's own infrastructure.

Severity: **High** = fix soon, real exposure or data-loss risk. **Medium** =
should fix. **Low** = hardening / defence-in-depth.

---

## Security

### S1 — Wildcard `*.lsck0.dev` is public and points at a stale IP (High)

`README.md` states internal services "resolve via CoreDNS only — no public DNS
exposure". They do not. A wildcard record exists at Cloudflare:

```
$ dig +short randomxyz123.lsck0.dev @1.1.1.1   -> 87.148.112.159
$ dig +short vault.lsck0.dev  @1.1.1.1          -> 87.148.112.159
$ dig +short proxmox.lsck0.dev @1.1.1.1         -> 87.148.112.159
$ dig +short wg.lsck0.dev @1.1.1.1              -> 79.225.65.177   (current WAN via DDNS)
```

Two problems:

1. Every internal service name (`vault`, `proxmox`, `grafana`, `torrent`, `nas`,
   `tasks`, …) is enumerable by anyone. The whole service inventory leaks.
2. `87.148.112.159` is **not** the current WAN (`79.225.65.177`). It is a stale,
   unproxied record. A client that trusts DNS and connects to a leaked internal
   name over the internet sends `Host: vault.lsck0.dev` (and any bearer cookie
   scoped to `lsck0.dev`) to whatever machine now holds that IP.

**Fix:** delete the wildcard `*.lsck0.dev` A record at Cloudflare. Keep only the
per-service records the DDNS script manages (external services). Internal names
already resolve through CoreDNS on the VPN/LAN, so nothing internal needs a
public record.

### S2 — qBittorrent Web UI has authentication disabled (High)

`117-internal-qbittorrent.nix` disables the built-in login and whitelists
`10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16`:

```
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
WebUI\LocalHostAuth=false
```

Authentik only guards the `torrent.lsck0.dev` route through Traefik. Anything
that can reach `10.100.0.117:80` directly — every host on the LAN, the VPN, and
every other internal VM — has full control with no login: add torrents, and
change the download path to write files anywhere the process can reach
(`/srv/downloads`, `/srv/media` over NFS).

**Fix:** keep the built-in auth on, or restrict the whitelist to the Traefik IP
(`10.100.0.100/32`) only, so direct access still requires a password.

### S3 — Authentik is pinned to a two-year-old release (High)

`101-internal-authentik.nix` runs `ghcr.io/goauthentik/server:2024.2.2`. This is
the primary SSO for the whole lab and is far behind on security fixes. The
Authelia work in this branch (vm-128) replaces it and is the better long-term
answer, but until the `sso` switch in `100-internal-traefik.nix` is flipped,
Authentik is still the gate — so either bump it to a current release or complete
the Authelia cutover.

### S4 — Traefik serves the default self-signed certificate (Medium)

Direct TLS to both entry points returns Traefik's built-in cert, not the ACME
wildcard:

```
$ openssl s_client -connect 10.100.0.100:443 -servername homepage.lsck0.dev
  subject=CN=TRAEFIK DEFAULT CERT
$ openssl s_client -connect 10.200.0.200:443 -servername hello.lsck0.dev
  subject=CN=TRAEFIK DEFAULT CERT
```

ACME is not issuing (or not loading) the `*.lsck0.dev` certificate. Public
services survive because Cloudflare terminates TLS at its edge, but every direct
path — VPN clients, LAN, and the Cloudflare→origin hop unless it is set to "Full
(strict)" — runs on an untrusted self-signed cert and is MITM-able.

**Fix:** confirm the Cloudflare DNS-challenge token and check
`/var/lib/traefik/acme/acme.json` on both Traefik VMs. Verify a real cert is
issued before relying on any direct access.

### S5 — Wildcard TLS private key committed to git (Medium)

`secrets/server-key.pem` is a tracked private key for `CN=*.lsck0.dev`
(`.gitignore` excludes only `secrets/age.txt`). The repo is private today, but a
key in history is one visibility change or one clone leak away from a wildcard
compromise, and nothing in `src/` even references it.

**Fix:** if unused, remove it and purge it from history. If used, move it to sops
and rotate the key.

### S6 — No security response headers on any route (Medium)

```
$ curl -skI https://10.200.0.200/ -H 'Host: hello.lsck0.dev'
  (no Strict-Transport-Security, Content-Security-Policy, X-Frame-Options,
   or X-Content-Type-Options)
```

No HSTS, CSP, framing, or MIME-sniffing protection on any app.

**Fix:** add a shared `secure-headers` middleware in `modules/traefik.nix` and
attach it to the router defaults (at least HSTS and `X-Content-Type-Options`).

### S7 — CI runner and Authentik worker mount the Docker socket as root (Medium)

`108-internal-forgejo-runner.nix` and the Authentik worker in
`101-internal-authentik.nix` both bind `/var/run/docker.sock` with `user: root`.
A mounted Docker socket is root on the host; the Forgejo runner additionally
executes CI jobs from the Git server, so any repo that runs there can escape to
host root on vm-108.

**Fix:** for the runner, prefer rootless Docker or a socket proxy
(`tecnativa/docker-socket-proxy`) restricted to the endpoints it needs. Keep CI
off the same host as anything sensitive (it already is — keep it that way).

### S8 — FileBrowser runs with `FB_NOAUTH=true` (Low)

`105-internal-nas.nix` serves the whole NAS with no login, relying only on the
Traefik/Authentik route. Direct access to `10.100.0.105:80` is unauthenticated
read/write over the entire `/srv/nas` tree. Same shape as S2, lower impact.

### S9 — Flat internal network (Low)

The router allows `ens19` (internal LAN) → anywhere, and each VM's firewall
trusts the whole `/24`. Database ports (Postgres on Authentik, Nextcloud, Huginn,
Wiki.js) and NFS are reachable from every internal VM. One compromised service
can reach every other. Consider per-service allowlists to just Traefik and the
specific dependencies.

### S10 — NFS exports use `no_root_squash` to the whole subnet (Low)

`105-internal-nas.nix` exports with `no_root_squash` to `10.100.0.0/24` (and
`/srv/nas/data` to the DMZ `10.200.0.0/24`). Root on any allowed host is root on
the exported files. Drop `no_root_squash` where the client does not truly need
it, and narrow the DMZ export to the specific VMs that mount it.

---

## Performance & Reliability

### P1 — NFS read-write mounts are `soft` (High, data-loss risk)

`modules/nas.nix`:

```
nfsOpts = [ "nfsvers=4" "rw" "soft" "timeo=15" ... ];
```

`soft` returns an I/O error to the application after `timeo` instead of
retrying. On a rw mount that means a NAS blip during a write can corrupt or lose
data silently — and this option is used for every persistent-data mount,
including the Postgres data directories. Use `hard` (optionally with `intr`) for
all read-write mounts; keep `soft` only for the read-only media mounts where a
failed read is harmless.

### P2 — Databases live on NFS (Medium)

Authentik, Nextcloud, Huginn and Wiki.js keep their Postgres/MariaDB data under
`/srv/nas/data/*` over NFS. Databases on NFS are prone to locking anomalies and
corruption and are slow. Combined with P1 this is the biggest reliability risk in
the lab. Prefer a local disk (or a Proxmox-backed volume) for DB data and back it
up with `pg_dump` to the NAS instead of storing the live files there.

### P3 — Global `powersave` CPU governor (Medium)

`modules/base.nix` sets `powerManagement.cpuFreqGovernor = "powersave"` on every
VM. Good for idle boxes, but it caps clocks on latency-sensitive VMs (both
Traefik instances, Authentik/Authelia, and the Hermes inference VM). Consider
`schedutil` or `ondemand` for those, keeping `powersave` as the default.

### P4 — 19 container images use the `:latest` tag (Medium)

Nineteen instances pin `:latest`. That defeats reproducibility (the stated IaC
goal): two deploys of the same commit can produce different running software, and
a bad upstream push breaks the lab with no rollback. Pin explicit tags or
digests, as Authentik and the Forgejo runner already do.

### P5 — Backup coverage (Low, verify)

`sync.sh` schedules vzdump for VMs 105 and 207 only; the NAS backup module tars
`/srv/nas/data/*` and copies it to the Proxmox host. Because every VM is rebuilt
from Nix, that covers the important mutable state — with one gap: data on a VM's
**local** disk is not backed up. Today that means the Hermes model cache (rebuilt
on demand, fine) and, if the Authelia cutover happens, its keys — but Authelia's
state dir is already on the NAS, and the Tor relay keys are backed up explicitly.
Confirm nothing else keeps unique state on a local disk.

---

## Gaps vs. stated goals

- **"One login, then access everywhere."** ForwardAuth gates the *routes*, but
  several apps still present their own login behind it (Jellyfin, the *arr apps),
  so it is not true SSO and the second login is not federated. Only Nextcloud,
  Vaultwarden and Forgejo use real OIDC. Wiring OIDC into Jellyfin (SSO plugin)
  and the *arr stack, or at least auto-provisioning users from the ForwardAuth
  headers, would close this.
- **"Fully monitored through Grafana."** Prometheus scrapes only
  `node-exporter`. There are no container metrics (cAdvisor), no Traefik metrics,
  no per-service dashboards, and no alerting. "Fully monitored" is not met yet.
- **"No secrets outside encrypted files."** Mostly true via sops — except
  `secrets/server-key.pem` (S5) and the committed `terraform.tfstate`, which
  holds infrastructure detail and cloud-init attributes in plaintext. Consider a
  remote/encrypted backend or at least gitignoring the state.

---

## Suggested order

1. S1 (delete wildcard DNS) — one Cloudflare change, removes the largest exposure.
2. S2 (qBittorrent auth) and P1 (`hard` NFS) — small diffs, high impact.
3. S3 (finish Authelia cutover or bump Authentik).
4. S4 (fix ACME) and S6 (security headers).
5. Everything else as hardening.
