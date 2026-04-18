{ ... }: {
  networking.hostName = "vm-106";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2";
    ports = [ "80:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
