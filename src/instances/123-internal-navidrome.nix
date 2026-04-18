{ ... }: {
  networking.hostName = "vm-123";

  fileSystems."/srv/music" = {
    device = "10.100.0.110:/srv/nas/media/music";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:latest";
    ports = [ "80:4533" ];
    volumes = [
      "/var/lib/navidrome:/data"
      "/srv/music:/music:ro"
    ];
    environment = {
      ND_SCANSCHEDULE = "1h";
      ND_LOGLEVEL = "info";
      ND_BASEURL = "";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/navidrome 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
