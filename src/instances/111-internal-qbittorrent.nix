{ pkgs, lib, nasMount, nasPath, retry, ... }:
let
  # hosts that may use the WebUI API without a login: internal Traefik (itself
  # behind Authelia), the *arr VMs, the wiring VM and Hermes. Explicit /32s, so
  # an arbitrary LAN host cannot rewrite download paths across the NFS mounts.
  # 104 is the terminal dashboard collector (transfer rates and torrent list).
  apiClients = map (id: "10.100.0.${toString id}/32") [ 100 104 113 130 131 133 135 136 ];

  # route all traffic through the Tor SOCKS5 gateway on vm-112.
  #
  # Tor carries TCP only, so DHT, PEX and LSD are turned off here: they are UDP
  # or LAN broadcast and would otherwise bypass the proxy and expose the real
  # WAN address. That also means peers are only discovered through trackers,
  # and inbound connections cannot arrive at all, so swarms will be small and
  # slow. A WireGuard VPN is the better tool if the goal is throughput.
  prefs = pkgs.writeText "qbittorrent-prefs.json" (builtins.toJSON {
    proxy_type = "SOCKS5";
    proxy_ip = "10.100.0.112";
    proxy_port = 9050;
    proxy_auth_enabled = false;
    proxy_hostname_lookup = true;
    proxy_bittorrent = true;
    proxy_peer_connections = true;
    proxy_misc = true;
    proxy_rss = true;
    anonymous_mode = true;
    save_path = "/data/torrents";
    bypass_auth_subnet_whitelist_enabled = true;
    bypass_auth_subnet_whitelist = lib.concatStringsSep ", " apiClients;
    dht = false;
    pex = false;
    lsd = false;
    # one download at a time. Everything goes through a single Tor circuit, so
    # parallel torrents split one slow pipe and all of them crawl; serialising
    # them means the first finishes at whatever speed the circuit allows.
    # Seeding is not capped, only active downloads.
    queueing_enabled = true;
    max_active_downloads = 1;
    max_active_torrents = 6;
    max_active_uploads = 5;
    dont_count_slow_torrents = true;
  });
in {
  networking.hostName = "vm-111";

  fileSystems = nasMount "/var/lib/qbittorrent" "qbittorrent"
    // nasPath "/data/torrents" "torrents"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls476";
    ports = [ "80:8080" "6881:6881" "6881:6881/udp" ];
    volumes = [
      "/var/lib/qbittorrent:/config"
      "/data/torrents:/data/torrents"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
      WEBUI_PORT = "8080";
    };
  };

  # disable built-in auth: authelia ForwardAuth handles access control
  systemd.services.qbittorrent-disable-auth = {
    description = "Disable qBittorrent built-in auth";
    after = [ "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      conf="/var/lib/qbittorrent/qBittorrent/qBittorrent.conf"
      ${retry} 60 2 test -f "$conf"

      # bootstrap only: loopback without login, so the Tor-proxy unit below can
      # push the real settings (incl. the API client whitelist) over the API.
      # qBittorrent writes its config back on shutdown, so edit it while stopped.
      if ! grep -qF 'WebUI\LocalHostAuth=false' "$conf"; then
        systemctl stop podman-qbittorrent.service
        sed -i '/^WebUI\\LocalHostAuth=/d' "$conf"
        if grep -q '^\[Preferences\]' "$conf"; then
          sed -i 's/^\[Preferences\]$/[Preferences]\nWebUI\\LocalHostAuth=false/' "$conf"
        else
          printf '\n[Preferences]\nWebUI\\LocalHostAuth=false\n' >> "$conf"
        fi
        systemctl start podman-qbittorrent.service
      fi
    '';
  };

  systemd.services.qbittorrent-tor-proxy = {
    description = "Configure qBittorrent: Tor SOCKS5 proxy, save path, API whitelist, WebUI password";
    after = [ "podman-qbittorrent.service" "qbittorrent-disable-auth.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman pkgs.jq pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      API="http://127.0.0.1:8080/api/v2"
      # run curl inside the container: only there is the request really from
      # loopback (WebUI\LocalHostAuth=false), a published port is not.
      curl() { podman exec qbittorrent curl "$@"; }
      ${retry} 60 2 podman exec qbittorrent curl -fsS "$API/app/version"

      # WebUI login for everything off the whitelist. Homepage and the *arr
      # download clients read it from the token files.
      T=/var/lib/homepage-tokens
      [ -s $T/qbittorrent-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/qbittorrent-pass.token
      echo -n admin > $T/qbittorrent-user.token

      prefs=$(jq -c --rawfile p $T/qbittorrent-pass.token '. + { web_ui_username: "admin", web_ui_password: $p }' ${prefs})
      curl -fsS -X POST "$API/app/setPreferences" --data-urlencode "json=$prefs"
      echo "qBittorrent proxied via Tor (10.100.0.112:9050)"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 6881 ];
  networking.firewall.allowedUDPPorts = [ 6881 ];

  # the WebUI skips its login for the whitelisted API clients, so the port
  # itself must not be reachable from anywhere else. 6881 (peer traffic) stays
  # open. apiClients is the same list the whitelist uses.
  homelab.ingressOnly = {
    ports = [ 80 ];
    extraSources = apiClients;
  };
}
