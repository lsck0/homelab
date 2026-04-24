{ pkgs, nasMount, nasPath, ... }: {
  networking.hostName = "vm-119";

  fileSystems = nasMount "/var/lib/homepage-tokens" "homepage-tokens"
    // nasMount "/var/lib/radarr" "radarr"
    // nasPath "/srv/downloads" "torrents"
    // nasPath "/srv/movies" "media/movies";

  virtualisation.oci-containers.containers.radarr = {
    image = "lscr.io/linuxserver/radarr:latest";
    ports = [ "80:7878" ];
    volumes = [
      "/var/lib/radarr:/config"
      "/srv/movies:/movies"
      "/srv/downloads:/downloads"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/radarr 0750 1000 1000 -"
  ];

  # Disable built-in auth — authentik ForwardAuth handles access control
  systemd.services.radarr-disable-auth = {
    description = "Disable Radarr built-in auth";
    after = [ "podman-radarr.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      conf="/var/lib/radarr/config.xml"
      for i in $(seq 1 60); do
        [ -f "$conf" ] && break
        sleep 2
      done
      [ ! -f "$conf" ] && exit 1

      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' "$conf"
      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationRequired>.*</AuthenticationRequired>|<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>|' "$conf"

      ${pkgs.podman}/bin/podman restart radarr
    '';
  };

  systemd.services.radarr-homepage-token = {
    description = "Export Radarr API key for Homepage";
    after = [ "podman-radarr.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/radarr-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      conf="/var/lib/radarr/config.xml"
      for i in $(seq 1 60); do [ -f "$conf" ] && break; sleep 2; done
      [ ! -f "$conf" ] && exit 1
      KEY=$(${pkgs.gnugrep}/bin/grep -oP '<ApiKey>\K[^<]+' "$conf")
      [ -n "$KEY" ] && echo -n "$KEY" > "$TOKEN_FILE"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
