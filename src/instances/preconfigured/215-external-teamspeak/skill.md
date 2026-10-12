---
name: teamspeak
description: TeamSpeak 6 server: the address, the admin token, and its state.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, TeamSpeak, Voice]
    related_skills: [homelab-ops]
---

# TeamSpeak (vm-215, 10.200.0.215, ts.lsck0.dev)

A TeamSpeak 6 server (the official image, container `teamspeak`) for the owner and friends. The router forwards
voice (udp 9987) and file transfer (tcp 30033) from the house's public address; ServerQuery (ssh 10022, http
10080) is off. Use `terminal` for all steps.

## Connect

Reply with the address `ts.lsck0.dev` (a TeamSpeak 6 client): 9987 is TeamSpeak's default port, so clients need
no port. Inside the lab the router also answers the SRV record `_ts3._udp.ts.lsck0.dev`; the public dns has the
A record alone.

## Admin privilege key

The first start of a fresh database prints the ServerAdmin privilege key once to the container log; the owner
claims server admin with it in the client:

`ssh 10.200.0.215 'podman logs teamspeak 2>&1 | grep -i token'`

It is never in the repo. Send it to the owner only. Once the log has rotated past it, the server's own log files
on the guest keep it: `ssh 10.200.0.215 'grep -ri token /var/lib/teamspeak/logs/'`.

## State and status

- `ssh 10.200.0.215 systemctl status podman-teamspeak`; `podman logs --tail 50 teamspeak`.
- The database and uploads live in `/var/lib/teamspeak` and are copied nightly to the nas share `data/teamspeak`
  (`teamspeak-mirror`, logs left out), which the nas backs up; a restore goes through `nas-restore`.
