---
name: build-caches
description: Nix binary cache (Attic) and sccache.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Nix, Attic, sccache]
    related_skills: [homelab-ops]
---

# Build caches

## Attic (vm-110, LXC, http://10.100.0.110:8080, https://attic.lsck0.dev, cache `homelab`)

Every VM uses it as a substituter. On vm-110: `atticd` service, client `attic`.
- Push a store path: `ssh 10.100.0.110 attic push homelab <path>` (client logged in as server admin).
- Storage: `du -sh /var/lib/atticd/storage`; garbage collection runs from atticd config.

## sccache (vm-110, redis://10.100.0.110:6379)

Shared Rust/C/C++ compile cache for CI (`SCCACHE_REDIS=redis://:<password>@sccache.lsck0.dev`).
Redis needs the password: on vm-110 run `redis-cli -p 6379 -a "$(cat /run/secrets/sccache-redis-pass)" --no-auth-warning <command>`.
- Stats: `info memory`; flush if corrupt: `flushall`.
