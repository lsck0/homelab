# Which exit each VM's traffic leaves through. Read by 300-router.nix, which
# enforces it with policy routing; a listed VM needs no config of its own.
#
#   vmid  the VM, as in instances.tf
#   via   "direct" (default, unlisted)  the house address via the WAN NAT
#         "tor"     transparently through the Tor client on the router
#         "vpn"     through the router's WireGuard tunnel. Needs
#                   homelab.egress.vpn.enable, or the build fails rather than
#                   letting a VM leak out of the house instead.
#
# tor is TCP-only: DNS is redirected, all other UDP dropped. That breaks QUIC,
# NTP and anything peer-to-peer - it was tried for qBittorrent, which held zero
# connections. Suits indexers and scrapers. Many sites block Tor exits outright.
#
# An app that can be pointed at a proxy should use the router's SOCKS ports
# instead (9050 shared, 9055 per-destination circuits): Prowlarr does, and gets
# stream isolation a transparent redirect cannot give.
{
  # The only VM needing an *inbound* port, which is why the tunnel lives on the
  # router: Proton leases one port per tunnel (scripts/protonvpn-port.sh), so
  # the shared exit can forward it here and nowhere else.
  qbittorrent = { vmid = 112; via = "vpn"; };

  # Add more as:
  #   prowlarr = { vmid = 129; via = "tor"; };
}
