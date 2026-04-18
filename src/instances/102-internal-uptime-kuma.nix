{ ... }: {
  networking.hostName = "vm-102";

  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:latest";
    ports = [ "80:3001" ];
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
