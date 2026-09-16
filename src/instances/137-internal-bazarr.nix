{ nasMount, nasMedia, ... }: {
  networking.hostName = "vm-137";

  # Bazarr — subtitle management for the Sonarr/Radarr libraries. Needs their
  # API keys wired in the Bazarr UI (Settings → Sonarr/Radarr) at runtime;
  # reaches them at 10.100.0.120 (sonarr) / 10.100.0.119 (radarr). Behind
  # Authelia at subs.lsck0.dev.
  fileSystems = nasMount "/var/lib/bazarr" "bazarr"
    // nasMedia "/srv/media" "";

  virtualisation.oci-containers.containers.bazarr = {
    image = "lscr.io/linuxserver/bazarr:latest";
    ports = [ "80:6767" ];
    volumes = [
      "/var/lib/bazarr:/config"
      "/srv/media:/media"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/bazarr 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
