{ nasMount, nasMedia, ... }: {
  networking.hostName = "vm-121";

  fileSystems = nasMount "/var/lib/jellyfin" "jellyfin"
    // nasMedia "/mnt/media" "";

  virtualisation.oci-containers.containers.jellyfin = {
    image = "jellyfin/jellyfin:latest";
    ports = [ "80:8096" ];
    volumes = [
      "/var/lib/jellyfin/config:/config"
      "/var/lib/jellyfin/cache:/cache"
      "/mnt/media:/media:ro"
    ];
    environment = {
      JELLYFIN_PublishedServerUrl = "https://jellyfin.internal";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyfin/config 0750 1000 1000 -"
    "d /var/lib/jellyfin/cache 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
