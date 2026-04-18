{ ... }: {
  networking.hostName = "vm-203";
  virtualisation.oci-containers.containers.share = {
    image = "stonith404/pingvin-share:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/pingvin-share:/opt/app/backend/data" ];
    environment = {
      TRUST_PROXY = "true";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/pingvin-share 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
