---
name: router-network
description: Router, firewall, DNS, DHCP, WireGuard and DDNS.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Network, DNS, Firewall, WireGuard]
    related_skills: [homelab-ops]
---

# Router (`luca-router`, 192.168.178.29 / 10.100.0.1 / 10.200.0.1)

`ssh 192.168.178.29 <cmd>`. NixOS config: `src/instances/300-router.nix`.

- Interfaces: ens18 WAN (FritzBox LAN), ens19 internal 10.100.0.0/24,
  ens20 DMZ 10.200.0.0/24, wg0 WireGuard 10.0.0.0/24.
- Firewall/NAT: nftables. `nft list ruleset`; forward rules: DMZ may only reach
  internal Traefik/registry/git, Loki (3100), Wazuh syslog (udp 514) and NFS.
  Port forwards (WAN IP): 443 -> vm-200, 25565 -> vm-200 (Minecraft), 9001 -> vm-202.
- DNS: CoreDNS (split horizon: *.lsck0.dev -> Traefik IPs) -> blocky (ad block, DoT).
  Test: `dig +short grafana.lsck0.dev @10.100.0.1`. Blocky: `journalctl -u blocky -n 50`;
  temporarily disable blocking: `curl -X GET http://127.0.0.1:4000/api/blocking/disable?duration=10m` (if the API port is enabled) or restart blocky.
- DHCP: Kea, leases `/var/lib/kea/dhcp4.leases`.
- WireGuard: `wg show wg0` (peers laptop .2, phone .3, tablet .4). New peers are
  Nix config; generate the client keys and tell the owner the peer block to add.
- DDNS: `systemctl start ddns-cloudflare` then `journalctl -u ddns-cloudflare -n 30`.
  Public records come from `src/modules/routes.nix`.
- Wake the owner's PC: `ssh 192.168.178.29 wakeonlan -i 192.168.178.255 10:ff:e0:e4:04:4a`.
- Debug reachability: `ping`, `tcpdump -ni ens19 host <ip>`, `conntrack -L` (if installed).
