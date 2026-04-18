{ pkgs, nasMount, nasMedia, nasPath, ... }: {
  networking.hostName = "vm-113";

  fileSystems = nasMount "/var/lib/qbittorrent" "qbittorrent"
    // nasMedia "/srv/media" ""
    // nasPath "/srv/downloads" "torrents";

  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:latest";
    ports = [ "80:8080" "6881:6881" "6881:6881/udp" ];
    volumes = [
      "/var/lib/qbittorrent:/config"
      "/srv/downloads:/downloads"
      "/srv/media:/media"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
      WEBUI_PORT = "8080";
    };
  };

  # Disable built-in auth — authentik ForwardAuth handles access control
  systemd.services.qbittorrent-disable-auth = {
    description = "Disable qBittorrent built-in auth";
    after = [ "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      conf="/var/lib/qbittorrent/qBittorrent/qBittorrent.conf"
      for i in $(seq 1 60); do
        [ -f "$conf" ] && break
        sleep 2
      done
      [ ! -f "$conf" ] && exit 1

      # Enable subnet whitelist bypass for all private ranges
      ${pkgs.gnused}/bin/sed -i '/\[Preferences\]/,/^\[/{
        /WebUI\\AuthSubnetWhitelistEnabled/d
        /WebUI\\AuthSubnetWhitelist/d
        /WebUI\\LocalHostAuth/d
      }' "$conf"
      ${pkgs.gnused}/bin/sed -i '/\[Preferences\]/a\
WebUI\\AuthSubnetWhitelistEnabled=true\
WebUI\\AuthSubnetWhitelist=10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16\
WebUI\\LocalHostAuth=false' "$conf"

      # Restart container to pick up config
      ${pkgs.podman}/bin/podman restart qbittorrent
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 6881 ];
  networking.firewall.allowedUDPPorts = [ 6881 ];
}
