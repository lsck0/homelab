{ ... }: {
  networking.hostName = "vm-110";

  virtualisation.oci-containers.containers.taskchampion-sync-server = {
    image = "ghcr.io/gothenburg-bit-factory/taskchampion-sync-server:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/taskchampion:/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
