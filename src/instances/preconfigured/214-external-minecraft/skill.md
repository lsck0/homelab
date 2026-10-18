---
name: minecraft
description: Minecraft servers: the addresses, modpacks, rcon, and how one sleeps and another wakes.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Minecraft, Games]
    related_skills: [homelab-ops]
---

# Minecraft (vm-214, 10.200.0.214, <server>.mc.lsck0.dev)

Whether vm-214 runs at all is its power in AGENTS.md: `on`, or `off` when the owner switched it off
(start it with `vm start 214` only when the owner asks for a server). While the VM runs, mc-gate on it
owns the public port 25565 for every server.

The servers, each at its own address:
- **cobblemon**, `cobblemon.mc.lsck0.dev`: the owner's custom Cobblemon pack, Minecraft 1.21.1.
- **vanilla**, `vanilla.mc.lsck0.dev`: plain Minecraft, the newest release.
- **atm**, `atm.mc.lsck0.dev`: the All the Mons modpack 1.3.0 (CurseForge), NeoForge 21.1.249. Players install
  the same pack version in their launcher. A pack update: put the new ServerFiles zip into
  `/var/lib/minecraft-modpacks/`, change `GENERIC_PACK` in `/var/lib/minecraft/atm/modpack.env` and in the
  repo's `servers.atm.pack`. Extra mods beyond the pack (Mahou Tsukai) are jars in
  `/var/lib/minecraft-modpacks/atm-extra/`, loaded on atm's next start; players need the same jars.
  The pack zip ships its own `config/` and the image re-extracts it on every start, so a changed config
  there is lost: put the changed file into `/var/lib/minecraft-modpacks/atm-config/` (copied over the pack's
  on every start, e.g. `mahoutsukai-server.toml`) and restart atm while nobody is on.

A player picks the server by the address they add in the launcher; the port stays the default 25565.

**One server is awake at a time.** mc-gate answers status pings itself, boots the server a real player
logs in to, and stops it after 30 minutes without players. A login for a second server while someone is
on the first is refused with a message naming who is on; after five minutes online with nobody there, the
next login switches: the first is stopped, the second started, and the player is kicked with "starting,
rejoin in a moment".

Use `terminal` for all steps.

## Start a server

Nothing to start: a server boots by itself when a player joins its address. Reply with the address
`<server>.mc.lsck0.dev`. The first join after a pack switch downloads the pack and takes several minutes.

- `ssh 10.200.0.214 mc-state` shows every server, its phase and who is on.
- `ssh 10.200.0.214 'journalctl -u minecraft-<server> -u mc-gate -n 30'` shows the boot;
  `Done (` means it is up.

## Switch modpack

`ssh 10.200.0.214 mc-modpack <server> <modpack> [minecraft-version]`

- `<server>`: one of the servers above.
- `<modpack>`: a Modrinth URL or slug (`https://modrinth.com/modpack/cobbleverse`),
  a CurseForge modpack URL, or `vanilla` (the default pack).
- It writes that server's pack and restarts it when it runs; otherwise the next join boots the new pack.
- Each pack keeps its own world (world name = pack slug); switching back restores that world.
- `ssh 10.200.0.214 mc-modpack` with no argument lists every server with its pack and phase.

If the owner sends a pack name instead of a URL, find it with `web_search` on
modrinth.com and use the URL.

## Server commands

`ssh 10.200.0.214 mc-rcon [-s <server>] <command>` (or `mc <command>` from here): e.g. `list`,
`whitelist add <player>`, `op <player>`, `say <text>`. Without `-s` it talks to the server that is awake,
and says so when none is. Only works while a server runs: rcon lives in its container.

The whitelist and the ops are **shared by every server** (`/var/lib/minecraft/whitelist.json` and
`ops.json`, bind mounted into each). `mc-rcon whitelist add <player>` is how someone new gets in, and it
needs a running server; with none awake, edit `/var/lib/minecraft/whitelist.json` by hand instead.

## Backup, restart, removal

- `ssh 10.100.0.104 nas-restore service minecraft` restores every server at once: they share one nas
  share, so one server cannot be rolled back alone.
- `systemctl restart mc-gate` cuts every player on, since every connection is relayed through it: do it
  only when `mc-state` shows nobody online. A changed server list needs no restart,
  `systemctl reload mc-gate` takes it.
- A deploy never restarts a running server, so nobody is kicked: a changed server takes effect when the gate
  next stops it (30 minutes without players). To apply it sooner, `systemctl restart minecraft-<server>`
  while `mc-state` shows nobody online.
- Removing a server is a change to `servers` in the repo, and only while that server sleeps: stopping a
  running one drops its players. Its data dir stays until the owner deletes it.
