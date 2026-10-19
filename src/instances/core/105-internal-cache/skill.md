---
name: cache
description: The ci runner's shared compile cache (sccache on redis).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, sccache, Redis]
    related_skills: [homelab-ops]
---

# Build cache

## sccache (vm-105, redis://10.100.0.105:6379)

Shared Rust/C/C++ compile cache for the forgejo runner's jobs (user `ci` on vm-111,
`SCCACHE_REDIS=redis://:<password>@sccache.lsck0.dev`). GitHub runners take strangers' pull requests and never
get it.
Redis needs the password: on vm-105 run `redis-cli -p 6379 -a "$(cat /run/secrets/sccache-redis-pass)" --no-auth-warning <command>`.
- Stats: `info memory`; flush if corrupt: `flushall`.
