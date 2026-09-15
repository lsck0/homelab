# Todo

## Done (branch: config staged, VMs disabled in terraform until you flip them on)

- [x] setup paperless AI for doc categorizing — vm-125, points at Hermes for local inference
- [x] make qbittorrent use tor-router — vm-127 SOCKS gateway; qbit proxied, DHT/PEX/LSD off
- [x] setup a non-exit tor node — vm-209, relay role, 2 MB/s cap, 500 GB/mo, keys backed up
- [x] setup a hermes agent vm — vm-126, Ollama serving hermes3:8b (CPU until GPU passthrough)
- [x] mark vms as "on-demand" — modules/on-demand.nix, socket-activated via Proxmox API; wired
      for Minecraft but OFF (needs proxmox-api-token). Caveat: polling (Homepage/Kuma) keeps VMs awake
- [x] authentik alternatives — vm-128 Authelia (~100 MB vs ~2 GB), switchable via `sso` in vm-100
- [x] TRMNL calendar + Kraken — vm-129 aggregates ICS + Kraken into trmnl.json feed
- [x] synced calendar (work outlook / uni studip / personal proton) — vm-129, merged.ics
      NOTE: fill published-ICS links in secrets (calendar-sources); work Outlook may block publish
- [x] security + performance audit — see AUDIT.md; 3 high-impact fixes applied

## Follow-ups from the audit (AUDIT.md has detail)

- [ ] S1: delete the wildcard *.lsck0.dev record at Cloudflare (biggest exposure, not a code change)
- [ ] S3: finish the Authelia cutover (flip `sso` in vm-100) or bump Authentik off 2024.2.2
- [ ] S4: fix ACME — both Traefiks currently serve the default self-signed cert
- [ ] "one login": wire OIDC into Jellyfin + the *arr apps for true SSO
- [ ] "fully monitored": add container/Traefik metrics + dashboards + alerting (only node-exporter now)

## Before enabling the new VMs

- [ ] provide secrets: proxmox-api-token (on-demand), calendar-sources / calendar-token,
      kraken-api-key / kraken-api-secret (optional). authelia-admin-pass already generated.
- [ ] flip `enabled = true` in src/instances/main.tf for the VMs you want live (125-129, 209)
