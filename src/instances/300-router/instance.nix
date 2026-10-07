# gateway: nat, firewall, dhcp, dns, wireguard, ddns
{ ... }: {
  # proxmox and the house know it by this name
  hostName = "luca-router";

  vm = {
    bootPhase = "network";
    memoryMiB = 1024;
    balloonMiB = 1024;
  };

  secrets = {
    protonvpn-private-key = "manual";
    wireguard-private-key = "manual"; # init.sh: wg genkey
  };
}
