{ ... }: {
  networking.hostName = "vm-107";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2";
    ports = [ "80:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
