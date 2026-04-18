{ ... }: {
  networking.hostName = "vm-205";
  virtualisation.oci-containers.containers.hello = {
    image = "nginxdemos/hello";
    ports = [ "80:80" ];
  };
  networking.firewall.allowedTCPPorts = [ 80 ];
}
