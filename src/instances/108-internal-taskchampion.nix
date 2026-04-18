{ config, lib, ... }: {
  networking.hostName = "vm-108";

  services.taskchampion-sync-server = {
    enable = true;
    port = 8080;
    openFirewall = true;
    dataDir = "/var/lib/taskchampion";
  };

  # Override: module hardcodes --listen 127.0.0.1, need 0.0.0.0
  systemd.services.taskchampion-sync-server.serviceConfig.ExecStart = let
    cfg = config.services.taskchampion-sync-server;
  in lib.mkForce ''
    ${lib.getExe cfg.package} \
      --listen "0.0.0.0:${toString cfg.port}" \
      --data-dir ${cfg.dataDir} \
      --snapshot-versions ${toString cfg.snapshot.versions} \
      --snapshot-days ${toString cfg.snapshot.days}
  '';

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
