# Which exit each VM leaves through. Enforced by 300-router.nix; a listed VM needs no config of its own.
#   vmid  the VM, as in instances.tf
#   via   "direct" (default) | "tor" | "vpn"
# vpn needs homelab.egress.vpn.enable, or the build fails rather than leaking.
# tor is TCP-only: DNS is redirected, other UDP dropped, so no QUIC/NTP/p2p.
# An app that can be pointed at a proxy should use the router's SOCKS (9050 shared, 9055 isolated) instead.
{
  # only VM needing an inbound port; Proton leases one per tunnel
  qbittorrent = { vmid = 112; via = "vpn"; };
}
