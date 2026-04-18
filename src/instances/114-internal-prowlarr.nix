{ nasMount, ... }: {
  networking.hostName = "vm-114";

  fileSystems = nasMount "/var/lib/prowlarr" "prowlarr";

  virtualisation.oci-containers.containers.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:latest";
    ports = [ "80:9696" ];
    volumes = [
      "/var/lib/prowlarr:/config"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/prowlarr 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
