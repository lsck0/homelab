---
name: minecraft
description: Minecraft server: modpacks, rcon, and how it sleeps and wakes.
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

The VM is always on (`enabled = true` in instances.tf); never `vm start` it. lazymc on the VM
owns the public port 25565: it answers status pings itself, boots the server container on a
real player login, and stops it after 30 minutes without players. Use `terminal` for all steps.

## Start the server

Nothing to start: the server boots by itself when a player joins. Reply with the address
`mc.lsck0.dev`. The first join after a pack switch downloads the pack and takes several minutes;
`ssh 10.200.0.208 'journalctl -u lazymc -n 20'` shows the boot, `Done (` means it is up.

## Switch modpack

`ssh 10.200.0.208 mc-modpack <modpack> [minecraft-version]`

- `<modpack>`: a Modrinth URL or slug (`https://modrinth.com/modpack/cobbleverse`),
  a CurseForge modpack URL, or `vanilla` (the default pack).
- It writes the pack and restarts lazymc; the next join boots the new pack.
- Each pack keeps its own world (world name = pack slug); switching back
  restores that world.
- `ssh 10.200.0.208 mc-modpack` with no argument shows the current pack.

If the owner sends a pack name instead of a URL, find it with `web_search` on
modrinth.com and use the URL.

## Server commands

`ssh 10.200.0.208 mc-rcon <command>`: e.g. `list`, `whitelist add <player>`,
`op <player>`, `say <text>`. Only works while the server is awake (a player is on).
