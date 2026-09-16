# Todo

## Done

- Core: Proxmox + NixOS fleet, Terraform-provisioned, one-command `./sync.sh` deploy.
- Ingress: Cloudflare (proxied) → FritzBox `:443` → router → external Traefik → service,
  with a catch-all relay to internal Traefik (zero device config).
- Identity: lldap (store + admin UI) + Authelia (SSO/OIDC + ForwardAuth, TOTP/WebAuthn two_factor).
  OIDC wired for Nextcloud/Vaultwarden/Forgejo. Forgejo is SSO-only (no signup, no anon browse).
- Edge security: CrowdSec bouncer + AppSec WAF (headscale/ntfy excluded) + per-IP rate/inflight
  limits + Slowloris timeouts + secure headers + CrowdSec whitelist (LAN + home prefix).
- Observability: Prometheus + Loki + Tempo + Grafana + Alertmanager → ntfy. One `Homelab`
  dashboard: world map (request origins by country) + HTTP + per-VM system + logs.
- Backups: restic (encrypted, deduped, verified, 7d/8w/12m) with `nas-restore` (incl. per-service).
- On-demand VMs: socket-activated boot on first request, idle-stop; `sync.sh` always deploys all.
- DNS: CoreDNS split-horizon + blocky adblock + DoT; DDNS keeps Cloudflare records current.
- Services deployed: traefik ×2, homepage, grafana, uptime-kuma, nas, sccache, forgejo (+runner),
  registry, authelia, lldap, attic, jellyseerr, bazarr, recyclarr, mosquitto, actual, firefly,
  headscale, searxng, shlink, privatebin, share, ntfy, minecraft, hello, router.

## Open (needs your input)

- SMTP relay creds (vm-132) — kills the Authelia file-notifier OTC dance.
- Off-site backup target (B2/S3/SFTP) — the 3rd copy for true 3-2-1 (restic ready).
- Telegram bot token + chat id — flip `enableTelegram` in vm-103.
- *arr media stack: enable VMs 111–124 (power cost) + API keys for widgets/Recyclarr/Bazarr.
- GPU passthrough (vm-126 Hermes) — needs a host reboot.
- Zigbee2MQTT / ESPHome / Frigate — physical hardware.

## Known limitations

- Anubis bot filter: off. Behind Cloudflare it only sees the rotating edge IP, re-challenges
  every request and breaks CSS. Module stays wired; re-enable if client-IP handling is solved.
- CrowdSec whitelist pins the home IPv6 `/48`; a dynamic ISP prefix rotation needs a one-line update.
