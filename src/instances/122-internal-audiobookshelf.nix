{ nasMount, nasPath, ... }: {
  networking.hostName = "vm-122";

  fileSystems = nasMount "/var/lib/audiobookshelf" "audiobookshelf"
    // nasPath "/srv/audiobooks" "media/audiobooks";

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
