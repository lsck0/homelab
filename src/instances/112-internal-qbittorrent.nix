{ ... }: {
  networking.hostName = "vm-112";

  fileSystems."/srv/downloads" = {
    device = "10.100.0.110:/srv/nas/torrents";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  fileSystems."/srv/media" = {
    device = "10.100.0.110:/srv/nas/media";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:latest";
    ports = [ "80:8080" "6881:6881" "6881:6881/udp" ];
    volumes = [
      "/var/lib/qbittorrent:/config"
      "/srv/downloads:/downloads"
      "/srv/media:/media"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
      WEBUI_PORT = "8080";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 6881 ];
  networking.firewall.allowedUDPPorts = [ 6881 ];
}
