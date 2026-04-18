{ ... }: {
  networking.hostName = "vm-123";

  fileSystems."/srv/downloads" = {
    device = "10.100.0.107:/srv/nas/torrents";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  fileSystems."/srv/movies" = {
    device = "10.100.0.107:/srv/nas/media/movies";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

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
