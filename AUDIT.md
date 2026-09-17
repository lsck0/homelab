# Homelab Security & Performance Audit

Living record of findings and their status. Testing is against the owner's own
infrastructure (static review of `src/` + live probing from LAN and public DNS).

Severity: **High** = real exposure / data-loss. **Medium** = should fix. **Low** = hardening.

## Resolved

- **S1 (High) Stale wildcard DNS**: `*.lsck0.dev` pointed at an old WAN IP. DDNS now
  keeps the wildcard + per-host proxied records current; all HTTP hosts proxied.
- **S3 (High) Authentik -> Authelia**: replaced; identity now lldap + Authelia (OIDC +
  ForwardAuth, two_factor via TOTP/WebAuthn). Forgejo SSO-only, no signup, no anon browse.
- **S4 ACME resolver dropped**: acme.json is chmod 600 on every start; real LE certs.
- **S6 Missing security headers**: HSTS/nosniff/frame-deny/referrer on every websecure route.
- **P1 (High) NFS `soft` risking corruption**: auth/DB state moved to local disk; `hard` for data.
- **P3 CPU governor**: `powersave` fleet-wide (bedroom noise/heat).
- **P6 Split-horizon DNS**: CoreDNS serves internal IPs to internal/VPN; public relay for LAN.
- **S2 (Medium) Default credentials**: qBittorrent, Kavita, Uptime Kuma, Audiobookshelf,
  Navidrome, Jellyfin, Wazuh, Huginn and Home Assistant used passwords written in this repo.
  Setup units now generate them and move existing installs off the old defaults.
- **S10 (High) DMZ could mount all service data**: `/srv/nas/data` was exported rw with
  `no_root_squash` to 10.200.0.0/24. Each DMZ VM now gets only its own shares
  (`dmzShares`, `modules/nas.nix`), with `subtree_check`; the build fails on any other mount.
- **S11 (Low) Postgres trust on the subnet**: Wiki.js and Huginn accept only the podman bridge.
- **P4 (Medium) Floating image tags**: every container image is pinned to a version.
- **P5 (Medium) Boot order**: VMs raced the NAS after a host reboot and stayed broken.
  Proxmox starts router, NAS, then the rest; NAS directories are created once the share
  is mounted, and containers retry without a start limit.
- **Ingress**: CrowdSec bouncer + AppSec WAF + rate/inflight limits + Slowloris `readTimeout`
  + CrowdSec whitelist (LAN + home). Real client IP via `trustCloudflare`.

## Open / residual

- **S12 (Medium) Home LAN is fully trusted**: the router accepts everything from
  192.168.178.0/24 into the lab, so any device there reaches services directly, without
  Authelia. The Samba `homelab` share gives guests read-write on all of `/srv/nas`, including
  the API tokens in `data/homepage-tokens`, and FileBrowser on vm-108 runs without auth.
  Fix: only admit the LAN to the Traefik VMs, DNS and the NAS SMB/NFS ports, and drop guest
  access from the `homelab` share (or the share itself).
- **S5 (High) Committed private key**: `secrets/server-key.pem` (key of the `*.lsck0.dev`
  certificate signed by the homelab CA) was tracked since Generation 77 and is public in git
  history. Untracked and gitignored now, together with the unused CA certificate (`secrets/`);
  nothing in the config uses either. Remove the homelab CA from every device that trusts it, or rotate the CA.
- **S7 (Low) docker.sock exposure**: swarm/registry VMs mount the socket; contain blast radius.
- **P2 (Medium) DBs on NFS**: some service DBs live on the NAS share; Kopia snapshots are
  file-level, not transaction-consistent. Add per-VM `pg_dump`/`sqlite .backup` before archiving.
- **S8 (Medium) Hermes has root everywhere**: by design (owner request). Blast radius of a
  prompt injection (e.g. a malicious document or web page) is the whole lab. Telegram access is
  limited to the owner's user id; Kopia keeps restorable history. Its repo access is a GitHub
  App on this repo only: branches and pull requests, no workflows, and the protect-master
  ruleset refuses its pushes to master (checked), so sync.sh never pulls unreviewed code.
  A deploy key was tried and dropped: on a personal repo it bypasses every ruleset.
- **Anubis (Low)**: disabled, it can't see the real client behind Cloudflare (edge-IP churn).
- **No off-site backup**: Kopia is local-only until a B2/S3/SFTP target is chosen (3-2-1 gap).
