{ nasMount, ... }: {
  networking.hostName = "vm-206";

  fileSystems = nasMount "/var/lib/privatebin" "privatebin";

  virtualisation.oci-containers.containers.privatebin = {
    image = "privatebin/nginx-fpm-alpine:2.0.4";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/privatebin:/srv/data" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/privatebin 0750 82 82 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
