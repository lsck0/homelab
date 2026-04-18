{ ... }: {
  networking.hostName = "vm-108";

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/homepage:/app/config" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
