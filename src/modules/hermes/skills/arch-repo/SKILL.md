---
name: arch-repo
description: The lsck0 pacman repo (nightly build on vm-119, served by vm-210 and vm-109) and the full official Arch mirror on vm-109.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Arch, Pacman, Mirror]
    related_skills: [on-demand, nas-storage, homelab-ops]
---

# Arch repo and mirror

Two separate things:

1. **lsck0 repo**: the packages of arch-dotfiles' `install.sh`, built every night, signed.
2. **Official mirror**: a full copy of Arch's core/extra/multilib (x86_64), so pacman pulls from the LAN.

## lsck0 repo build (vm-119, on-demand VM, https://archbuild.lsck0.dev status page)

- `archbuild.service` (oneshot, up to 20h) builds in two podman containers: `archbuild-build` runs the
  recipes and holds no secret, `archbuild-publish` signs and pushes. Only commits signed by the owner's
  key on arch-dotfiles `master` are built.
- The VM is woken at 03:00 by the internal traefik. `archbuild-if-stale.timer` starts a build when
  the last finished one is older than 20h. While a build runs, `/busy` answers 200 and the
  on-demand reaper leaves the VM up.
- Start a build now: `vm start 119`, wait for ssh, then `ssh 10.100.0.119 systemctl start --no-block archbuild.service`.
- Watch it: `ssh 10.100.0.119 journalctl -fu archbuild` or `curl -s http://10.100.0.119/status.txt`.
  Per-package logs: `http://10.100.0.119/logs/<pkgbase>.log`. Whole run: `/build.log`.
- Never stop it mid-publish. A deploy does not restart it (`restartIfChanged = false`).
- Output lands on the NAS at `/srv/nas/bulk/archrepo` (vm-109 serves it on :8090 for the LAN), and is
  pushed with rsync to vm-210 (`mirror.lsck0.dev`, public, plain http, signed packages).

## Official mirror (vm-109, /srv/nas/bulk/archmirror)

- `archmirror-sync.service`, hourly timer, from `rsync://ftp.halifax.rwth-aachen.de/archlinux/`,
  capped at 60 MiB/s, idle I/O priority. It checks upstream `lastupdate` first, so an unchanged
  upstream costs one tiny transfer.
- Size: about 122 GiB on the bulk HDD (not the "60 GiB" an old comment says).
- Served at `http://10.100.0.109:8090/archlinux/$repo/os/$arch` to internal, LAN, WireGuard and tailnet only.
- Start a sync now: `ssh 10.100.0.109 systemctl start --no-block archmirror-sync.service`. A second
  start while one runs is a no-op (flock on `/run/archmirror-sync.lock`).
- Status: `ssh 10.100.0.109 'systemctl status archmirror-sync; cat /srv/nas/bulk/archmirror/lastupdate'`.
  `lastupdate` is a unix timestamp; compare it with `date +%s`.
- Disk: `ssh 10.100.0.109 df -h /srv/nas/bulk`. The media quota does not cover the mirror.
