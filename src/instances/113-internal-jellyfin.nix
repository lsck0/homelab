{ ... }: {
  networking.hostName = "vm-113";

  # Mount media from NAS
  fileSystems."/mnt/media" = {
    device = "10.100.0.107:/srv/nas/media";
    fsType = "nfs";
    options = [ "nfsvers=4" "ro" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  virtualisation.oci-containers.containers.jellyfin = {
    image = "jellyfin/jellyfin:latest";
    ports = [ "80:8096" ];
    volumes = [
      "/var/lib/jellyfin/config:/config"
      "/var/lib/jellyfin/cache:/cache"
      "/mnt/media:/media:ro"
    ];
    environment = {
      JELLYFIN_PublishedServerUrl = "https://jellyfin.internal.local";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyfin/config 0750 1000 1000 -"
    "d /var/lib/jellyfin/cache 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
