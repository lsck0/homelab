# Which exit each VM's traffic leaves the lab through.
#
# Read by the router (300-router.nix), which enforces it with policy routing,
# and by the Tor gateway (113-internal-tor-router.nix). A VM listed here needs
# no configuration of its own: it keeps its ordinary default route to the
# router, and the router decides where the packets go. That is the point - the
# old arrangement made each VM run its own tunnel (modules/vpn.nix), so the
# choice of exit was buried in the VM and could only be changed by rebuilding
# it.
#
#   vmid  the VM, as in instances.tf
#   via   "direct"  the house's own address, through the WAN NAT. The default
#                   for anything not listed, so the file only names exceptions.
#         "tor"     transparently through the Tor client on the router. TCP only,
#                   see the warning below.
#         "vpn"     through the WireGuard tunnel the router holds. Requires
#                   homelab.egress.vpn.enable on the router; a VM asking for an
#                   exit that is not configured fails the build rather than
#                   quietly leaving through the house.
#
# ── what "tor" actually does ────────────────────────────────────────────────
# Tor carries TCP and nothing else. The router sends a tor-class VM's TCP to
# the router, which redirects it into Tor's TransPort, and its DNS to Tor's
# DNSPort. Every other UDP packet is dropped, because there is nowhere for it
# to go and letting it take the direct route would defeat the whole exercise.
#
# So a tor-class VM loses: QUIC/HTTP3 (browsers fall back to TCP, most other
# things do not), NTP, UDP trackers, anything peer-to-peer. It was tried for
# qBittorrent and did not work - every UDP tracker answered "Permission denied"
# and the client held zero connections - which is why vm-112 uses a VPN and not
# this. Tor suits things that make a modest number of outbound TCP requests and
# want a different address each time: indexers, scrapers, feed pollers.
#
# Many sites also block Tor exits outright, Cloudflare among them.
#
# ── tor vs. a SOCKS proxy ───────────────────────────────────────────────────
# the router still offers SOCKS on 9050 and 9055, and an app that can be pointed at
# a proxy should use that instead of this: Prowlarr does (129-internal-prowlarr.nix),
# and gets per-destination circuit isolation that a transparent redirect cannot
# give. This is for whole VMs, and for programs with no proxy setting.
{
  # qBittorrent. The only VM that needs an *inbound* port, which is why it also
  # decides where the tunnel lives: Proton leases exactly one port per tunnel
  # (scripts/protonvpn-port.sh), so the one shared exit forwards it to this VM
  # and no other. Outbound is not scarce in the same way - one tunnel carries
  # every member, because that is what a router does.
  qbittorrent = { vmid = 112; via = "vpn"; };

  # Add more as:
  #   prowlarr = { vmid = 129; via = "tor"; };
}
