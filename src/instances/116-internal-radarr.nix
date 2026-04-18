{ nasMount, nasPath, ... }: {
  networking.hostName = "vm-116";

  fileSystems = nasMount "/var/lib/radarr" "radarr"
    // nasPath "/srv/downloads" "torrents"
    // nasPath "/srv/movies" "media/movies";

  virtualisation.oci-containers.containers.radarr = {
    image = "lscr.io/linuxserver/radarr:latest";
    ports = [ "80:7878" ];
    volumes = [
      "/var/lib/radarr:/config"
      "/srv/movies:/movies"
      "/srv/downloads:/downloads"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/radarr 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
