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

`ssh 192.168.178.29 <cmd>`. NixOS config: `src/instances/core/300-router/main.nix`; the policy it renders is data in
`src/modules/flows.nix` (who may reach whom, with the reason per line), the zones in `src/generated/zones.json`.

- Interfaces: ens18 WAN (FritzBox LAN), one leg per zone of `src/generated/zones.json` (ens19 internal, ens20 DMZ, ens21
  apps zone, the swarm workers), wg0 WireGuard 10.0.0.0/24.
- Firewall/NAT: nftables. `nft list ruleset`; the forward chain is `inet nixos-fw forward-allow`. Defaults:
  WireGuard reaches everything, the house LAN reaches internal and DMZ, every zone (the internal one too) reaches
  the internet and nothing private except the `forward` lines of flows.nix (hermes, the ingresses, the dashboard and
  vm-103 to Proxmox, the edge's relay to vm-100:443, Loki and journal uploads to vm-103, NFS for vm-104's clients,
  the edge's Proxmox wake, the apps' published ports; the workers' registry pulls, telemetry and the swarm manager
  vm-107's 2377/7946/4789/esp). Lab traffic to Proxmox (192.168.178.200) keeps its source; everything else to the
  house is masqueraded. The router's own services (ssh, dns, dhcp, node exporter, tor) are the `router` lines of
  flows.nix.
- Refusals: each network's drop counts into `counter fwd-deny-<network>` (`nft list counters`, exported as
  `homelab_forward_denied_packets_total{network}`) and logs `fwd-deny <network>: ` (`journalctl -k -g fwd-deny`,
  rate limited).
- Anti-spoofing: table `ip antispoof` drops a source arriving on an interface it does not belong to
  (`nft list chain ip antispoof prerouting`, counters per interface). Inside a zone Proxmox's ip/mac filter binds
  each guest to its address (src/terraform/lib.tf `ipfilter`).
- Port forwards (WAN IP, from the internet, the house and WireGuard): 443 -> vm-200; every tcp/udp route
  straight to its backend while its guest is enabled (25565 -> vm-214, the wildcard host *.mc; udp 9987,
  tcp 30033 -> vm-215).
  `nft list table ip port-forwards`. The FritzBox forwards only the ports it is told to (443, 25565, udp 9987,
  tcp 30033 to 192.168.178.29): a new public port also needs a FritzBox port share, or it stops at the FritzBox.
  New clients of a route with `accessLog`: `journalctl -k -g 'dnat 25565: '` (rate-capped, level info).
- DNS: CoreDNS (split horizon: *.lsck0.dev -> the ingresses) -> blocky (ad block, DoT); blocky down: DoT to
  Cloudflare, never plain dns. VPN members (`profiles.vpnEgress`) resolve through Proton's resolver inside the
  tunnel and nothing else, tor members through tor. Test: `dig +short grafana.lsck0.dev @10.100.0.1`. A house
  client asking the FritzBox gets the public address and hairpins through it (the edge sees the house's public
  address); one asking the router (the workstation, through the dotfiles' networkmanager module) goes straight to the ingress as itself.
  Blocky: `journalctl -u blocky -n 50`.
- DHCP: Kea on the zones with a pool in zones.json, leases `/var/lib/kea/dhcp4.leases`.
- VPN exit: `wg show wg-egress`, `ip rule` (fwmark 0x1 lookup 100), `nft list chain ip egress killswitch`. Its
  servers are `homelab.egress.vpn.servers` (main.nix); `wg-egress-failover` moves to the next when the handshake is
  over 180 s old (`journalctl -u wg-egress-failover`, metric `homelab_vpn_handshake_age_seconds`).
- Tor exit (`on = profiles.torEgress`): a member's internet tcp is redirected into tor's TransPort 9040, its names go to
  the DNSPort (127.0.0.1:9053), the rest is dropped. `nft list chain ip egress torredirect`, `cat
  /var/lib/node-exporter-textfile/tor.prom` (0: no circuit, the tor_unavailable alert), `journalctl -u tor -n 50`.
- Onion services (a public route's `onion = true`): tor publishes each from its seed (secret <route>-onion-key, kind
  onion) to the edge's onion entrypoint 10.200.0.200:8090. Address: `cat /run/tor/onion/<route>/hostname`, the same
  as src/generated/onions.json. Keys: `systemctl status tor-onion-keys`.
- WireGuard: `wg show wg0` (peers laptop .2, phone .3, tablet .4, pc .5). New peers are
  Nix config; generate the client keys and tell the owner the peer block to add.
- Public address: `public-address` and `public-prefix` ask the FritzBox over UPnP (lib/public-address.nu;
  "Statusinformationen ueber UPnP" must be on); `cat /run/public-address/hosts /run/public-address/prefix6`.
- DDNS: `systemctl start ddns-cloudflare` then `journalctl -u ddns-cloudflare -n 30` (src/instances/core/300-router/lib/ddns-cloudflare.nu).
  Public records come from the route catalog; a failed run leaves the address unsynced and the next run retries.
- WAN limits: `nft list table ip wan-limits` (per internet source syn rate and connection count; the house, by its
  lan or its public address (set house_public, `systemctl status wan-limits-house`), and Cloudflare exempt).
- Wake the owner's PC: `ssh 192.168.178.29 wol-pc` (its mac is the router's secret `workstation-mac`).
- Debug reachability: `ping`, `tcpdump -ni ens19 host <ip>`, `conntrack -L` (if installed).
