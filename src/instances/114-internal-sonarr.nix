{ ... }: {
  networking.hostName = "vm-114";

  fileSystems."/srv/downloads" = {
    device = "10.100.0.110:/srv/nas/torrents";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  fileSystems."/srv/tv" = {
    device = "10.100.0.110:/srv/nas/media/tv";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

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
