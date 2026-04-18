{ ... }: {
  networking.hostName = "vm-202";

  virtualisation.oci-containers.containers.privatebin = {
    image = "privatebin/nginx-fpm-alpine:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/privatebin:/srv/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
