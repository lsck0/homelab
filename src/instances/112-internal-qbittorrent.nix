{ config, pkgs, lib, nasMount, nasPath, retry, ... }:
let
  # webui api without login for these hosts
  incompleteDir = "/var/lib/qbittorrent-incomplete";

  apiClients = map (id: "10.100.0.${toString id}/32") [ 1 100 104 114 130 ];

  # router routes peer traffic, no proxy here
  prefs = pkgs.writeText "qbittorrent-prefs.json" (builtins.toJSON {
    proxy_type = "None";
    proxy_bittorrent = false;
    proxy_peer_connections = false;
    proxy_misc = false;
    proxy_rss = false;
    # anonymous_mode hides fingerprint and ip; off
    anonymous_mode = false;
    save_path = "/data/torrents";
    # download to the vm's own nvme disk, move to the hdd once: the hdd sleeps between finished downloads,
    # and the disk's size caps what unfinished torrents can take
    temp_path_enabled = true;
    temp_path = "/data/incomplete";
    bypass_auth_subnet_whitelist_enabled = true;
    bypass_auth_subnet_whitelist = lib.concatStringsSep ", " apiClients;
    # dht and pex find the swarm
    dht = true;
    pex = true;
    lsd = true;
    # webui on 80, where arr and traefik expect it
    web_ui_port = 80;
    # placeholder, protonvpn-port sets the leased port
    listen_port = 6881;
    random_port = false;
    upnp = false;
    queueing_enabled = true;
    max_active_downloads = 5;
    # no seeding, so upload slots only matter for queued finished torrents
    max_active_uploads = 8;
    max_active_torrents = 13;
    dont_count_slow_torrents = true;
    # download only: stop on completion, the arr imports then removes it
    max_ratio_enabled = true;
    max_ratio = 0;
    max_seeding_time_enabled = true;
    max_seeding_time = 0;
    max_ratio_act = 0;
  });
in {
  networking.hostName = "vm-112";

  # egress: router holds the tunnel and killswitch; dns asks the provider through it, never from the home ip
  networking.nameservers = lib.mkForce [ "10.2.0.1" ];

  fileSystems = nasMount "/var/lib/qbittorrent" "qbittorrent"
    // nasPath "/data" "bulk"
    // {
      # instances.tf extra disk; nofail plus RequiresMountsFor: a missing disk stops qbittorrent, not the boot
      "${incompleteDir}" = {
        device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
        fsType = "ext4";
        autoFormat = true;
        options = [ "noatime" "nofail" ];
      };
    };

  # host networking, not a published port
  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls476";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/qbittorrent:/config"
      "/data/torrents:/data/torrents"
      "${incompleteDir}:/data/incomplete"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
      WEBUI_PORT = "80";
    };
  };

  # authelia forwardauth replaces built-in auth
  systemd.services.qbittorrent-disable-auth = {
    description = "Disable qBittorrent built-in auth";
    after = [ "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      conf="/var/lib/qbittorrent/qBittorrent/qBittorrent.conf"
      ${retry} 60 2 test -f "$conf"

      # bootstrap login-free loopback, edited while stopped
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

  systemd.services.qbittorrent-settings = {
    description = "Configure qBittorrent: peer settings, save path, API whitelist, WebUI password";
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
      API="http://127.0.0.1:80/api/v2"
      # exec inside the container for true loopback
      curl() { podman exec qbittorrent curl "$@"; }
      ${retry} 60 2 podman exec qbittorrent curl -fsS "$API/app/version"

      # webui login for non-whitelisted clients
      T=${config.homelab.tokens.dir}
      [ -s $T/qbittorrent-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/qbittorrent-pass.token
      echo -n admin > $T/qbittorrent-user.token

      prefs=$(jq -c --rawfile p $T/qbittorrent-pass.token '. + { web_ui_username: "admin", web_ui_password: $p }' ${prefs})
      curl -fsS -X POST "$API/app/setPreferences" --data-urlencode "json=$prefs"
      echo "qBittorrent configured: direct peer traffic, DHT/PEX/LSD on, 5 active downloads"
    '';
  };

  systemd.services.podman-qbittorrent.unitConfig.RequiresMountsFor = [ incompleteDir ];

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
    "d ${incompleteDir} 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];

  # leased port changes, so match on public source; iptables host, extraInputRules would be nftables-only
  networking.firewall.extraCommands = ''
    iptables -N homelab-peers 2>/dev/null || iptables -F homelab-peers
    ${lib.concatMapStrings (s: ''
      iptables -A homelab-peers -s ${s} -j RETURN
    '') [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "127.0.0.0/8" ]}
    iptables -A homelab-peers -p tcp --dport 1024:65535 -j nixos-fw-accept
    iptables -A homelab-peers -p udp --dport 1024:65535 -j nixos-fw-accept
    iptables -A nixos-fw -j homelab-peers
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -j homelab-peers 2>/dev/null || true
    iptables -F homelab-peers 2>/dev/null || true
    iptables -X homelab-peers 2>/dev/null || true
  '';

  # uid 1000 in the container binds 80
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  # whitelisted api clients skip the login
  homelab.ingressOnly = {
    ports = [ 80 ];
    extraSources = apiClients;
  };
}
