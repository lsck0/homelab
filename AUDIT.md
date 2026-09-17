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
- **Ingress**: CrowdSec bouncer + AppSec WAF + rate/inflight limits + Slowloris `readTimeout`
  + CrowdSec whitelist (LAN + home). Real client IP via `trustCloudflare`.

## Open / residual

- **S2 (Medium) qBittorrent default creds**: `admin/adminadmin` in the Homepage widget; rotate
  when vm-111 is enabled.
- **S5 (High) Committed private key**: `secrets/server-key.pem` (key of the `*.lsck0.dev`
  certificate signed by the homelab CA) was tracked since Generation 77 and is public in git
  history. Untracked and gitignored now (`secrets/*` except the CA certificate); nothing in the
  config uses it. Remove the homelab CA from every device that trusts it, or rotate the CA.
- **S7 (Low) docker.sock exposure**: swarm/registry VMs mount the socket; contain blast radius.
- **P2 (Medium) DBs on NFS**: some service DBs live on the NAS share; Kopia snapshots are
  file-level, not transaction-consistent. Add per-VM `pg_dump`/`sqlite .backup` before archiving.
- **S8 (Medium) Hermes has root everywhere**: by design (owner request). Blast radius of a
  prompt injection (e.g. a malicious document or web page) is the whole lab. Telegram access is
  limited to the owner's user id; Kopia keeps restorable history.
- **S9 (Low) Wazuh default dashboard password**: only reachable through Traefik + Authelia.
- **Anubis (Low)**: disabled, it can't see the real client behind Cloudflare (edge-IP churn).
- **No off-site backup**: Kopia is local-only until a B2/S3/SFTP target is chosen (3-2-1 gap).
