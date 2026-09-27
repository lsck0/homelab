# which exit each vm leaves through
{
  # needs an inbound port; proton leases one per tunnel
  qbittorrent = { vmid = 112; via = "vpn"; };
}
