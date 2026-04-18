{ ... }: {
  networking.hostName = "vm-117";

  fileSystems."/srv/audiobooks" = {
    device = "10.100.0.110:/srv/nas/media/audiobooks";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  virtualisation.oci-containers.containers.audiobookshelf = {
    image = "ghcr.io/advplyr/audiobookshelf:latest";
    ports = [ "80:80" ];
    volumes = [
      "/srv/audiobooks:/audiobooks"
      "/var/lib/audiobookshelf/config:/config"
      "/var/lib/audiobookshelf/metadata:/metadata"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/audiobookshelf/config 0750 1000 1000 -"
    "d /var/lib/audiobookshelf/metadata 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
