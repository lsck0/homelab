---
name: public-apps
description: Shlink links, PrivateBin, file share, SearXNG.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Shlink, SearXNG, Sharing]
    related_skills: [homelab-ops]
---

# Public apps (DMZ)

## Shlink URL shortener (vm-205, https://shlink.lsck0.dev)

API key: `lab-token shlink-key`, base `http://10.200.0.205/rest/v3`, header `X-Api-Key`.
- Shorten: `POST /short-urls {"longUrl":"https://...","customSlug":"optional","tags":["hermes"]}` -> `.shortUrl`.
- List: `GET /short-urls?searchTerm=<t>`; stats `GET /short-urls/<code>/visits`; delete `DELETE /short-urls/<code>`.

## SearXNG (vm-204, on demand, https://search.lsck0.dev)

`vm start 204`, then `curl -s 'http://10.200.0.204/search?q=<q>&format=json'` (if JSON format is enabled
in settings; otherwise use your own `web_search`).

## PrivateBin (vm-206, on demand, https://paste.lsck0.dev)

End-to-end encrypted in the browser; creating pastes needs client-side encryption
(`pbincli` if available). Prefer sending text directly on Telegram.

## Share (vm-207, on demand, https://share.lsck0.dev)

Pingvin Share for public download links: upload in its web UI or API
(`/api/shares`, needs a Pingvin user). For quick sharing to the owner, attach on Telegram instead.
