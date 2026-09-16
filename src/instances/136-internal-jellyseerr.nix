{ nasMount, ... }: {
  networking.hostName = "vm-136";

  # Jellyseerr — media request/discovery front-end for Jellyfin + the *arr
  # stack. Behind Authelia at requests.lsck0.dev.
  fileSystems = nasMount "/var/lib/jellyseerr" "jellyseerr";

  virtualisation.oci-containers.containers.jellyseerr = {
    image = "docker.io/fallenbagel/jellyseerr:latest";
    ports = [ "80:5055" ];
    volumes = [ "/var/lib/jellyseerr:/app/config" ];
    environment = {
      TZ = "Europe/Berlin";
      PORT = "5055";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyseerr 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
