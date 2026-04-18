{ ... }: {
  networking.hostName = "vm-201";
  virtualisation.oci-containers.containers.shlink = {
    image = "shlinkio/shlink:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/shlink:/etc/shlink/data" ];
  };
  networking.firewall.allowedTCPPorts = [ 80 ];
}
