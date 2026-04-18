{ ... }: {
  networking.hostName = "vm-203";
  virtualisation.oci-containers.containers.share = {
    image = "lscr.io/linuxserver/nextcloud:latest";
    ports = [ "80:80" ];
    volumes = [ "/var/lib/share:/config" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/share 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
