---
name: public-apps
description: PrivateBin, file share, SearXNG.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, SearXNG, Sharing]
    related_skills: [homelab-ops]
---

# Public apps (DMZ)

## SearXNG (vm-204, on demand, https://search.lsck0.dev)

While it is up (else ask the owner to start it), `curl -s 'http://10.200.0.204/search?q=<q>&format=json'`. The limiter lets
vm-114 through; engine traffic leaves via the VPN.

## PrivateBin (vm-206, on demand, https://paste.lsck0.dev)

End-to-end encrypted in the browser; creating pastes needs client-side encryption
(`pbincli` if available). Prefer sending text directly on Telegram.

## Share (vm-207, on demand, https://share.lsck0.dev)

Pingvin Share for public download links: upload in its web UI or API
(`/api/shares`, needs a Pingvin user). For quick sharing to the owner, attach on Telegram instead.
