# which exit each vm leaves through
{
  # needs an inbound port; proton leases one per tunnel
  qbittorrent = { vmid = 112; via = "vpn"; };
  # engine traffic: neither strangers' searches nor the owner's point at the house ip, and engines rate-limit the tunnel
  searxng = { vmid = 204; via = "vpn"; };
}
