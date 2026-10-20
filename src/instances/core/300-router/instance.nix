# gateway: nat, firewall, dhcp, dns, wireguard, the vpn and tor exits, ddns
_: {
  # proxmox and the house know it by this name
  hostName = "luca-router";

  vm = {
    bootPhase = "network";
    # every zone guest needs its dhcp, dns and routes: it starts right after the nas, ahead of the network phase
    bootOrder = 1;
    # 537 MiB peak over 35d
    memoryMiB = 768;
  };

  # tor down or cut off: the tor egress members have no internet (killswitch), prowlarr's searches fail
  alerts.tor_unavailable = {
    title = "Tor unavailable";
    category = "upstream";
    expr = "max(homelab_tor_circuit_established)";
    op = "lt";
    threshold = 1;
    for = "15m";
    summary = "tor unavailable";
    description = "The router's tor has had no circuit for 15 minutes: guests whose egress is tor reach no internet and prowlarr's indexer searches fail. `systemctl status tor` and `journalctl -u tor -n 50` on the router.";
  };

  # every server of the exit without a handshake: the vpn members have no internet (killswitch)
  alerts.vpn_unavailable = {
    title = "VPN exit unavailable";
    category = "upstream";
    expr = "max(homelab_vpn_handshake_age_seconds)";
    threshold = 600;
    for = "10m";
    summary = "the VPN exit has had no handshake for {{ humanizeDuration $values.A.Value }}";
    description = "The router moved through its servers (egress-vpn.nix) and none answers: guests whose egress is vpn reach no internet. `wg show wg-egress` and `journalctl -u wg-egress-failover` on the router; add a server to homelab.egress.vpn.servers.";
  };

  secrets = {
    protonvpn-private-key = "manual";
    wireguard-private-key = "guardsData:wireguard"; # every wireguard client peers with its public half
    workstation-mac = "manual"; # init.nu: the workstation's mac, for wol-pc
  };
}
