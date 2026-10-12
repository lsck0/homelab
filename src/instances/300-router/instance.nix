# gateway: nat, firewall, dhcp, dns, wireguard, the vpn and tor exits, ddns
{ ... }: {
  # proxmox and the house know it by this name
  hostName = "luca-router";

  vm = {
    bootPhase = "network";
    memoryMiB = 1024;
    balloonMiB = 1024;
  };

  # tor down or cut off: the tor egress members have no internet (killswitch), prowlarr's searches fail
  alerts.tor_unavailable = {
    title = "Tor unavailable";
    category = "upstream";
    expr = "max(homelab_tor_circuit_established)";
    op = "lt"; threshold = 1;
    for = "15m";
    summary = "tor unavailable";
    description = "The router's tor has had no circuit for 15 minutes: guests whose egress is tor reach no internet and prowlarr's indexer searches fail. `systemctl status tor` and `journalctl -u tor -n 50` on the router.";
  };

  secrets = {
    protonvpn-private-key = "manual";
    wireguard-private-key = "guardsData:wireguard"; # every wireguard client peers with its public half
    workstation-mac = "manual"; # init.sh: the workstation's mac, for wol-pc
  };
}
