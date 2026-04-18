{ ... }: {
  networking.hostName = "vm-102";

  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:latest";
    ports = [ "80:3001" ];
    volumes = [ "/var/lib/uptime-kuma:/app/data" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/uptime-kuma 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
