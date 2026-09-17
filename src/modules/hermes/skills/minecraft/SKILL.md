---
name: minecraft
description: Start the Minecraft server and switch modpacks.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Minecraft, Games]
    related_skills: [homelab-ops]
---

# Minecraft (vm-208, 10.200.0.208, mc.lsck0.dev)

The VM is on demand: it boots when a player connects and shuts down after
its cooldown without players. Use `terminal` for all steps.

## Start the server

1. `vm start 208`
2. Wait until the game port answers: `ssh 10.200.0.208 'podman logs --tail 20 minecraft'`
   and look for `Done (` or poll `nc -z 10.200.0.208 25565`. A first start of a
   new modpack downloads it and takes several minutes.
3. Reply with the address `mc.lsck0.dev`.

## Switch modpack

`ssh 10.200.0.208 mc-modpack <modpack> [minecraft-version]`

- `<modpack>`: a Modrinth URL or slug (`https://modrinth.com/modpack/cobbleverse`),
  a CurseForge modpack URL, or `vanilla`.
- Each pack keeps its own world (world name = pack slug); switching back
  restores that world. The original world is `world` (cobbleverse).
- `ssh 10.200.0.208 mc-modpack` with no argument shows the current pack.

If the owner sends a pack name instead of a URL, find it with `web_search` on
modrinth.com and use the URL.

## Server commands

`ssh 10.200.0.208 mc-rcon <command>`: e.g. `list`, `whitelist add <player>`,
`op <player>`, `say <text>`.
