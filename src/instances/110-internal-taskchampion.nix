{ ... }: {
  networking.hostName = "vm-110";

  services.taskchampion-sync-server = {
    enable = true;
    port = 8080;
    openFirewall = true;
    dataDir = "/var/lib/taskchampion";
  };

  # Ensure server binds all interfaces (LISTEN env var for newer versions)
  systemd.services.taskchampion-sync-server.environment.LISTEN = "0.0.0.0:8080";

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
