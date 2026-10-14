# Specs

| Spec | Capability | Implemented in | Last reconcile |
|---|---|---|---|
| spec-001-minecraft | Minecraft servers on vm-214: sleep, wake, packs, and the target of several servers one at a time | `src/instances/preconfigured/214-external-minecraft/`; partial (the wildcard host of p1): `src/modules/service.nix` `src/modules/catalog.nix` `src/modules/lab-export.nix` `src/core/300-router/main.nix` | 2026-10-14 @ b66f6d0 |

## Unspecified

Everything else under `src/` is unspecified for now, and so is the rest of the four files spec-001 covers partially.
A change that touches unspecified code writes or extends the spec covering it.
