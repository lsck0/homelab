---
name: router
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

# Router (`luca-router`, 192.168.178.29 / 10.100.0.1 / 10.200.0.1 / 10.250.0.1)

`ssh 192.168.178.29 <cmd>`. NixOS config: `src/instances/300-router/main.nix`; the policy it renders is data in
`src/modules/flows.nix` (who may reach whom, with the reason per line), the zones in `src/generated/zones.json`.

- Interfaces: ens18 WAN (FritzBox LAN), one leg per zone of `src/generated/zones.json` (ens19 internal, ens20 DMZ, ens21
  apps zone, the swarm workers), wg0 WireGuard 10.0.0.0/24.
- Firewall/NAT: nftables. `nft list ruleset`; the forward chain is `inet nixos-fw forward-allow`. Defaults:
  internal and WireGuard reach everything, the house LAN reaches internal and DMZ, the DMZ and the apps zone reach
  the internet and nothing private except the `forward` lines of flows.nix (the edge's relay to vm-100:443, Loki and
  journal uploads to vm-105, NFS for vm-109's clients, the edge's Proxmox wake, the apps' published ports; the
  workers' registry pulls, telemetry and the swarm manager vm-140's 2377/7946/4789/esp).
  The router's own services (ssh, dns, dhcp, node exporter, tor) are the `router` lines of flows.nix.
- Anti-spoofing: table `ip antispoof` drops a source arriving on an interface it does not belong to
  (`nft list chain ip antispoof prerouting`, counters per interface). Inside a zone Proxmox's ip/mac filter binds
  each guest to its address (src/terraform/lib.tf FIREWALL).
- Port forwards (WAN IP, from the internet, the house and the trusted zones): 443 -> vm-200; every tcp/udp route
  straight to its backend while its guest is enabled (25565 -> vm-208). `nft list table ip port-forwards`.
- DNS: CoreDNS (split horizon: *.lsck0.dev -> the ingresses) -> blocky (ad block, DoT); blocky down: DoT to
  Cloudflare, never plain dns. VPN members (an instance.nix `egress`) resolve through Proton's resolver inside the
  tunnel and nothing else. Test: `dig +short grafana.lsck0.dev @10.100.0.1`. Blocky: `journalctl -u blocky -n 50`.
- DHCP: Kea on the zones with a pool in zones.json, leases `/var/lib/kea/dhcp4.leases`.
- VPN exit: `wg show wg-egress`, `ip rule` (fwmark 0x1 lookup 100), `nft list chain ip egress killswitch`.
- WireGuard: `wg show wg0` (peers laptop .2, phone .3, tablet .4, pc .5). New peers are
  Nix config; generate the client keys and tell the owner the peer block to add.
- DDNS: `systemctl start ddns-cloudflare` then `journalctl -u ddns-cloudflare -n 30` (src/instances/300-router/lib/ddns-cloudflare.sh).
  Public records come from the route catalog; a failed run leaves the address unsynced and the next run retries.
- WAN limits: `nft list table ip wan-limits` (per internet source syn rate and connection count; the house and
  Cloudflare exempt).
- Wake the owner's PC: `ssh 192.168.178.29 wakeonlan -i 192.168.178.255 10:ff:e0:e4:04:4a`.
- Debug reachability: `ping`, `tcpdump -ni ens19 host <ip>`, `conntrack -L` (if installed).
