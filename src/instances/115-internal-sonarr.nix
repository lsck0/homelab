{ nasMount, nasPath, ... }: {
  networking.hostName = "vm-115";

  fileSystems = nasMount "/var/lib/sonarr" "sonarr"
    // nasPath "/srv/downloads" "torrents"
    // nasPath "/srv/tv" "media/tv";

  virtualisation.oci-containers.containers.sonarr = {
    image = "lscr.io/linuxserver/sonarr:latest";
    ports = [ "80:8989" ];
    volumes = [
      "/var/lib/sonarr:/config"
      "/srv/tv:/tv"
      "/srv/downloads:/downloads"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/sonarr 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
