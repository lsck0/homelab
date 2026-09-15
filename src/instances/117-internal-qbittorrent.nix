{ pkgs, nasMount, nasMedia, nasPath, ... }: {
  networking.hostName = "vm-117";

  fileSystems = nasMount "/var/lib/qbittorrent" "qbittorrent"
    // nasMedia "/srv/media" ""
    // nasPath "/srv/downloads" "torrents"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

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
    path = [ pkgs.gnused pkgs.podman pkgs.coreutils ];
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

      # Remove old auth lines if present
      sed -i '/WebUI.AuthSubnetWhitelist/d; /WebUI.LocalHostAuth/d' "$conf"

      # Whitelist only the internal Traefik (10.100.0.100), which already sits
      # behind Authentik/Authelia ForwardAuth. A broad subnet whitelist would
      # let any LAN or VPN host reach 10.100.0.117:80 directly with no login and
      # change the download path to write files across the NFS mounts.
      if ! grep -q 'AuthSubnetWhitelistEnabled' "$conf"; then
        printf '\n[Preferences]\nWebUI\\AuthSubnetWhitelistEnabled=true\nWebUI\\AuthSubnetWhitelist=10.100.0.100/32\nWebUI\\LocalHostAuth=false\n' >> "$conf"
      fi

      # Restart container to pick up config
      podman restart qbittorrent
    '';
  };

  # Route all qBittorrent traffic through the Tor SOCKS5 gateway on vm-127.
  #
  # Tor carries TCP only, so DHT, PEX and LSD are turned off here: they are UDP
  # or LAN broadcast and would otherwise bypass the proxy and expose the real
  # WAN address. That also means peers are only discovered through trackers,
  # and inbound connections cannot arrive at all, so swarms will be small and
  # slow. A WireGuard VPN is the better tool if the goal is throughput.
  systemd.services.qbittorrent-tor-proxy = {
    description = "Point qBittorrent at the Tor SOCKS5 proxy";
    after = [ "podman-qbittorrent.service" "qbittorrent-disable-auth.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      API="http://127.0.0.1/api/v2"
      # WebUI\LocalHostAuth=false means loopback needs no credentials.
      for i in $(seq 1 60); do
        curl -fsS "$API/app/version" >/dev/null 2>&1 && break
        sleep 2
      done
      curl -fsS "$API/app/version" >/dev/null || { echo "qBittorrent API unreachable"; exit 1; }

      curl -fsS -X POST "$API/app/setPreferences" --data-urlencode 'json={
        "proxy_type": "SOCKS5",
        "proxy_ip": "10.100.0.127",
        "proxy_port": 9050,
        "proxy_auth_enabled": false,
        "proxy_hostname_lookup": true,
        "proxy_bittorrent": true,
        "proxy_peer_connections": true,
        "proxy_misc": true,
        "proxy_rss": true,
        "anonymous_mode": true,
        "dht": false,
        "pex": false,
        "lsd": false
      }'
      echo "qBittorrent proxied via Tor (10.100.0.127:9050)"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
  ];

  # Export qBittorrent credentials for Homepage widget
  systemd.services.qbittorrent-homepage-token = {
    description = "Export qBittorrent credentials for Homepage";
    after = [ "podman-qbittorrent.service" "qbittorrent-disable-auth.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/qbittorrent-user.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # With auth disabled for local subnet, credentials don't matter
      # but the widget requires them
      echo -n "admin" > /var/lib/homepage-tokens/qbittorrent-user.token
      echo -n "adminadmin" > /var/lib/homepage-tokens/qbittorrent-pass.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 6881 ];
  networking.firewall.allowedUDPPorts = [ 6881 ];
}
