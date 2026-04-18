{ ... }: {
  networking.hostName = "vm-110";

  services.taskchampion-sync-server = {
    enable = true;
    port = 8080;
    dataDir = "/var/lib/taskchampion";
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
