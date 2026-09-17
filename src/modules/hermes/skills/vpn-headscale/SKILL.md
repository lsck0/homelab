---
name: vpn-headscale
description: Headscale/Tailscale mesh: nodes, keys, routes.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, VPN, Headscale, Tailscale]
    related_skills: [homelab-ops]
---

# VPN

## Headscale (vm-201, https://hs.lsck0.dev, MagicDNS domain vpn.lsck0.dev)

Run on the VM: `ssh 10.200.0.201 headscale <cmd>`.
- Users: `headscale users list`, create `headscale users create <name>`.
- Nodes: `headscale nodes list`; remove `headscale nodes delete -i <id>`; rename `headscale nodes rename -i <id> <name>`.
- Join key for a new device: `headscale preauthkeys create --user <id-or-name> --expiration 1h`
  -> device runs `tailscale up --login-server https://hs.lsck0.dev --authkey <key>`.
- Subnet routes: `headscale nodes list-routes`, approve `headscale nodes approve-routes -i <id> -r <cidr>`.

## WireGuard on the router

Static peers (laptop, phone, tablet) on wg0, see `router-network`.
