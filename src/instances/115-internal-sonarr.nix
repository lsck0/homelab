{ pkgs, nasMount, nasPath, ... }: {
  networking.hostName = "vm-115";

  fileSystems = nasMount "/var/lib/sonarr" "sonarr"
    // nasPath "/srv/downloads" "torrents"
    // nasPath "/srv/tv" "media/tv";

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

  # Disable built-in auth — authentik ForwardAuth handles access control
  systemd.services.sonarr-disable-auth = {
    description = "Disable Sonarr built-in auth";
    after = [ "podman-sonarr.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      conf="/var/lib/sonarr/config.xml"
      for i in $(seq 1 60); do
        [ -f "$conf" ] && break
        sleep 2
      done
      [ ! -f "$conf" ] && exit 1

      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' "$conf"
      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationRequired>.*</AuthenticationRequired>|<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>|' "$conf"

      ${pkgs.podman}/bin/podman restart sonarr
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
