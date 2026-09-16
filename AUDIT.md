# Homelab Security & Performance Audit

Living record of findings and their status. Testing is against the owner's own
infrastructure (static review of `src/` + live probing from LAN and public DNS).

Severity: **High** = real exposure / data-loss. **Medium** = should fix. **Low** = hardening.

## Resolved

- **S1 (High) Stale wildcard DNS** — `*.lsck0.dev` pointed at an old WAN IP. DDNS now
  keeps the wildcard + per-host proxied records current; all HTTP hosts proxied.
- **S3 (High) Authentik → Authelia** — replaced; identity now lldap + Authelia (OIDC +
  ForwardAuth, two_factor via TOTP/WebAuthn). Forgejo SSO-only, no signup, no anon browse.
- **S4 ACME resolver dropped** — acme.json is chmod 600 on every start; real LE certs.
- **S6 Missing security headers** — HSTS/nosniff/frame-deny/referrer on every websecure route.
- **P1 (High) NFS `soft` risking corruption** — auth/DB state moved to local disk; `hard` for data.
- **P3 CPU governor** — `powersave` fleet-wide (bedroom noise/heat).
- **P6 Split-horizon DNS** — CoreDNS serves internal IPs to internal/VPN; public relay for LAN.
- **Ingress** — CrowdSec bouncer + AppSec WAF + rate/inflight limits + Slowloris `readTimeout`
  + CrowdSec whitelist (LAN + home). Real client IP via `trustCloudflare`.

## Open / residual

- **S2 (Medium) qBittorrent default creds** — `admin/adminadmin` in the Homepage widget; rotate
  when vm-117 is enabled.
- **S5 (Medium) Committed public key** — the age *public* key is in `.sops.yaml` (safe); the
  private key stays gitignored. Confirm no private material is ever committed.
- **S7 (Low) docker.sock exposure** — swarm/registry VMs mount the socket; contain blast radius.
- **P2 (Medium) DBs on NFS** — some service DBs live on the NAS share; restic dumps are
  file-level, not transaction-consistent. Add per-VM `pg_dump`/`sqlite .backup` before archiving.
- **Anubis (Low)** — disabled: can't see the real client behind Cloudflare (edge-IP churn).
- **No off-site backup** — restic is local-only until a B2/S3/SFTP target is chosen (3-2-1 gap).
