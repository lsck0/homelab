{ ... }: {
  networking.hostName = "vm-113";

  virtualisation.oci-containers.containers.jellyfin = {
    image = "jellyfin/jellyfin:latest";
    ports = [ "80:8096" ];
    volumes = [
      "/var/lib/jellyfin/config:/config"
      "/var/lib/jellyfin/cache:/cache"
      "/mnt/media:/media"
    ];
  };

  systemd.tmpfiles.rules = [ "d /mnt/media 0777 root root -" ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
