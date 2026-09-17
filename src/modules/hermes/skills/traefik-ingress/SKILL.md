---
name: traefik-ingress
description: Traefik routes, TLS, CrowdSec bans and WAF.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Traefik, CrowdSec, TLS]
    related_skills: [homelab-ops]
---

# Ingress

- Internal Traefik vm-100 (10.100.0.100): every `*.lsck0.dev` app, Authelia
  ForwardAuth in front. External Traefik vm-200 (10.200.0.200): public apps,
  CrowdSec bouncer + AppSec WAF + rate limits, relays everything else to vm-100.
- Routes are generated from `src/modules/routes.nix` (host -> vm + port).
- Dashboard: https://traefik.lsck0.dev. API from the VM:
  `ssh 10.100.0.100 curl -s localhost:8080/api/http/routers | jq '.[].name'`
  (use the port the dashboard entrypoint listens on; `ss -ltnp | grep traefik`).
- Logs: `journalctl -u traefik -n 100`; access log `/var/log/traefik/access.log` (JSON).
- Certificates: ACME via Cloudflare DNS, stored in `/var/lib/traefik/acme/acme.json` (NAS).

## CrowdSec (container `crowdsec` on vm-100 and vm-200)

- Current bans: `ssh 10.200.0.200 podman exec crowdsec cscli decisions list`
- Unban an IP: `podman exec crowdsec cscli decisions delete --ip <ip>`
- Ban manually: `podman exec crowdsec cscli decisions add --ip <ip> --duration 24h --reason manual`
- Alerts: `podman exec crowdsec cscli alerts list`; metrics `cscli metrics`.
- LAN, VPN and the home IPv6 prefix are whitelisted.

## Typical problems

- 404 from Traefik: no route for that host (check routes.nix / router list).
- 502/504: backend down; check the VM (`vm status <id>`, `podman ps`) or on-demand wake logs.
- 403 on vm-200: WAF or `internal-only` middleware (registry is blocked publicly by design).
