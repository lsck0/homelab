{ nasMount, nasMedia, ... }: {
  networking.hostName = "vm-124";

  fileSystems = nasMount "/var/lib/kavita" "kavita"
    // nasMedia "/srv/manga" "manga";

  virtualisation.oci-containers.containers.kavita = {
    image = "jvmilazz0/kavita:latest";
    ports = [ "80:5000" ];
    volumes = [
      "/var/lib/kavita:/kavita/config"
      "/srv/manga:/manga:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kavita 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
