# Which exit each VM leaves through.
{
  # only VM needing an inbound port; Proton leases one per tunnel
  qbittorrent = { vmid = 112; via = "vpn"; };
}
