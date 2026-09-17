# Todo

## Done

- Core: Proxmox + NixOS fleet, Terraform-provisioned, one-command `./sync.sh` deploy.
- Ingress: Cloudflare (proxied) -> FritzBox `:443` -> router -> external Traefik -> service,
  with a catch-all relay to internal Traefik (zero device config).
- Identity: lldap (store + admin UI) + Authelia (SSO/OIDC + ForwardAuth, TOTP/WebAuthn two_factor).
  OIDC wired for Nextcloud/Vaultwarden/Forgejo. Forgejo is SSO-only (no signup, no anon browse).
- Edge security: CrowdSec bouncer + AppSec WAF (headscale/ntfy excluded) + per-IP rate/inflight
  limits + Slowloris timeouts + secure headers + CrowdSec whitelist (LAN + home prefix).
- Observability: Prometheus + Loki + Tempo + Grafana + Alertmanager -> ntfy. One `Homelab`
  dashboard: world map (request origins by country) + HTTP + per-VM system + logs.
- Backups: Kopia (daily, deduped, zstd, 7d/8w/12m/2y) with web UI + `nas-restore` (incl. per-service).
- On-demand VMs: `enabled = "onDemand"` + `cooldown` in instances.tf; socket-activated boot on first
  request, idle-stop, reaper for VMs started without a request; `sync.sh` always deploys all.
- DNS: CoreDNS split-horizon + blocky adblock + DoT; DDNS keeps Cloudflare records current.
- Services deployed: traefik ×2, homepage, grafana, uptime-kuma, nas, sccache, forgejo (+runner),
  registry, authelia, lldap, attic, kopia, wazuh, hermes, *arr + jellyfin + janitorr, lidarr,
  bookshelf, suwayomi, jellyseerr, bazarr, recyclarr, mosquitto, paperless, firefly,
  headscale, searxng, shlink, privatebin, share, ntfy, minecraft, hello, router.

## Open (needs your input)

- Run `src/scripts/renumber.sh` (dry run), then `src/scripts/renumber.sh --execute`, then
  `./sync.sh`. VM ids now follow the order in instances.tf; sync.sh refuses to run before this.
  Free space on the Proxmox root disk first.
- Hermes secrets: run `src/scripts/hermes-secrets.sh` (SSH key, Anthropic API key, Telegram bot token + user id).
- Firefly: register the first user at firefly.lsck0.dev (Hermes' API token is created afterwards).
- Suwayomi: install manga sources (extensions) once in the UI.
- Off-site backup target (B2/S3/SFTP) for a Kopia repository sync (3-2-1).
- Wazuh: change the default dashboard password; agents (FIM/SCA) instead of syslog-only.
- Zigbee2MQTT / ESPHome / Frigate: physical hardware.

## Known limitations

- Anubis bot filter: off. Behind Cloudflare it only sees the rotating edge IP, re-challenges
  every request and breaks CSS. Module stays wired; re-enable if client-IP handling is solved.
- CrowdSec whitelist pins the home IPv6 `/48`; a dynamic ISP prefix rotation needs a one-line update.
