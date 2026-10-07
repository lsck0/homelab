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
  CrowdSec bouncer + AppSec WAF + rate limits, relays each internal host to vm-100 under its own router
  (`<name>-relay`, tls verified for that host). A host no router names gets a 404 at vm-200.
- Routes are the instances' `services` (`src/instances/<folder>/instance.nix`) and the apps' `routes`
  (`src/apps/<name>/app.nix`), one schema (`src/modules/service.nix`), merged in `src/modules/catalog.nix`; every
  protection is on unless a route says `off.<feature> = "<why>"`.
- Every websecure router runs, in order: client-ip (sets `X-Real-Ip` to the real client: the socket peer, or the
  X-Forwarded-For hop before Cloudflare and the edge; never a client-sent X-Real-Ip), the header strip,
  cloudflare-only (proxied routes on vm-200), the crowdsec bouncer, rate and in-flight limits per client, retries,
  security headers. Password endpoints (`loginPaths`) get `rate-limit-login` (5/min per client) on vm-100.
- The apps zone (10.250.0.0/24) gets a 404 on vm-100 for everything but the registry's pull route.
- Dashboard: https://traefik.lsck0.dev. API from the VM:
  `ssh 10.100.0.100 curl -s localhost:8080/api/http/routers | jq '.[].name'`
  (use the port the dashboard entrypoint listens on; `ss -ltnp | grep traefik`).
- Logs: `journalctl -u traefik -n 100`; access log `/var/log/traefik/access.log` (JSON).
- Certificates: one ACME wildcard `*.lsck0.dev` per ingress via Cloudflare DNS, in
  `/var/lib/traefik/acme/acme.json` on the VM's own disk (a lost file is re-issued).

## CrowdSec (container `crowdsec` on vm-100 and vm-200)

- Current bans: `ssh 10.200.0.200 podman exec crowdsec cscli decisions list`
- Unban an IP: `podman exec crowdsec cscli decisions delete --ip <ip>`
- Ban manually: `podman exec crowdsec cscli decisions add --ip <ip> --duration 24h --reason manual`
- Alerts: `podman exec crowdsec cscli alerts list`; metrics `cscli metrics`.
- LAN, VPN and the home IPv6 prefix are whitelisted. CrowdSec's state is on the VM's disk and regenerates.
- Access log: the client crowdsec and the limits acted on is the `request_X-Real-Ip` field.

## Bots (vm-200 only)

- `robots.txt` and `llms.txt` are served for every host by a local nginx, on a
  router with priority 10000 so nothing shadows them.
- A request whose User-Agent matches a known scraper is routed to **iocaine**
  (`systemctl status iocaine`, loopback :42069) instead of the real backend: it
  answers with generated prose and links to more of itself. The agent list is
  `labyrinthUserAgents` in `src/modules/traefik`.
- **Anubis** proof-of-work sits in front of every route without authelia that keeps the feature (searxng,
  privatebin, share, hello). One instance per ingress listens on 127.0.0.1:27000 and hands solved requests back
  to traefik on 127.0.0.1:28080, so `ss -ltnp` shows Traefik talking to loopback. It reads the client from
  `X-Real-Ip` and issues one clearance cookie for `lsck0.dev`.
- If a real client is being challenged in a loop, the switch is `off.anubis = "<why>"` on that route plus a
  deploy of the ingress. Say so rather than editing it yourself.

## Typical problems

- 404 from Traefik: no route for that host or method (check the instance's `services` / router list).
- 502/504: backend down; check the VM (`vm status <id>`, `podman ps`) or on-demand wake logs.
  A single 502 on an on-demand service right after it was shut down is expected
  to be retried away: every route carries a `retry-upstream` middleware.
- 403 on vm-200: WAF or `internal-only` middleware. `registry` and `attic` are
  blocked publicly by design (headless, token-only, no browser login).
- A page loads without CSS, or every request re-challenges: Anubis client-IP or
  cookie problem, see above.
- A browser gets nonsense prose: its User-Agent matched the labyrinth list.
