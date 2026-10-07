# qbittorrent: the arrs' download client, peers through the router's vpn exit
{ config, pkgs, lib, inventory, catalog, instance, nasMount, nasPath, retry, setupUnit, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  route = catalog.internal.qbittorrent;
  configDir = "/var/lib/qbittorrent";
  incompleteDir = "/var/lib/qbittorrent-incomplete";
  # inside and outside the container alike: the arrs resolve the save paths it reports on their own /data mount
  torrentsDir = "/data/torrents";
  incompleteMount = "/data/incomplete";
  # linuxserver images run the app as this uid and gid
  appId = "1000";
  webUiUser = "admin";
  peerPorts = "1024:65535";

  # the webui skips its own login for the ingress and every source instance.nix grants the port
  apiClients = [ (net.hostSource net.zones.${instance.zone}.ingress) ] ++ lib.concatMap (g: g.sources) instance.config.grants;

  # download only: finished torrents stop at once (ratio 0) for the arrs to import; upload slots serve queued ones
  activeDownloadsMax = 5;
  activeUploadsMax = 8;

  # router routes peer traffic, no proxy here
  prefs = pkgs.writeText "qbittorrent-prefs.json" (builtins.toJSON {
    proxy_type = "None";
    proxy_bittorrent = false;
    proxy_peer_connections = false;
    proxy_misc = false;
    proxy_rss = false;
    anonymous_mode = false;
    save_path = torrentsDir;
    # download to the vm's own nvme disk, move to the hdd once: the hdd sleeps between finished downloads
    temp_path_enabled = true;
    temp_path = incompleteMount;
    bypass_auth_subnet_whitelist_enabled = true;
    bypass_auth_subnet_whitelist = lib.concatStringsSep ", " apiClients;
    # dht and pex find the swarm
    dht = true;
    pex = true;
    lsd = true;
    web_ui_port = route.port;
    # placeholder, protonvpn-port sets the leased port
    listen_port = 6881;
    random_port = false;
    upnp = false;
    queueing_enabled = true;
    max_active_downloads = activeDownloadsMax;
    max_active_uploads = activeUploadsMax;
    # every slot of both kinds may be busy at once
    max_active_torrents = activeDownloadsMax + activeUploadsMax;
    dont_count_slow_torrents = true;
    # download only: stop on completion, the arr imports then removes it
    max_ratio_enabled = true;
    max_ratio = 0;
    max_seeding_time_enabled = true;
    max_seeding_time = 0;
    max_ratio_act = 0;
  });
in {
  # egress: router holds the tunnel and killswitch; dns asks the provider through it, never from the home ip
  networking.nameservers = lib.mkForce [ config.homelab.egress.vpn.gateway ];

  homelab.nasMounts = nasMount configDir "qbittorrent"
    // nasPath "/data" "bulk";
  # instance.nix extra disk; nofail plus RequiresMountsFor: a missing disk stops qbittorrent, not the boot
  fileSystems."${incompleteDir}" = {
    device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
    fsType = "ext4";
    autoFormat = true;
    options = [ "noatime" "nofail" ];
  };

  # host networking, not a published port
  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls476";
    extraOptions = [ "--network=host" ];
    volumes = [
      "${configDir}:/config"
      "${torrentsDir}:${torrentsDir}"
      "${incompleteDir}:${incompleteMount}"
    ];
    environment = {
      PUID = appId;
      PGID = appId;
      TZ = site.timeZone;
      WEBUI_PORT = toString route.port;
    };
  };

  # authelia forwardauth replaces built-in auth
  systemd.services.qbittorrent-disable-auth = setupUnit {
    description = "Disable qBittorrent built-in auth";
    after = [ "podman-qbittorrent.service" ];
    path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
    script = ''
      conf="${configDir}/qBittorrent/qBittorrent.conf"
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

  sops.secrets.qbittorrent-pass = { };

  systemd.services.qbittorrent-settings = setupUnit {
    description = "Configure qBittorrent: peer settings, save path, API whitelist, WebUI password";
    after = [ "podman-qbittorrent.service" "qbittorrent-disable-auth.service" ];
    path = [ pkgs.podman pkgs.jq pkgs.coreutils ];
    script = ''
      API="http://127.0.0.1:${toString route.port}/api/v2"
      # curl inside the container: its loopback is the one the webui lets in without a login
      ${retry} 60 2 podman exec qbittorrent curl -fsS "$API/app/version"

      # webui login for clients off the whitelist
      printf ${webUiUser} | token_write qbittorrent-user

      # the preferences carry the password: on stdin, not on argv
      jq -cj --rawfile p ${config.sops.secrets.qbittorrent-pass.path} '. + { web_ui_username: "${webUiUser}", web_ui_password: $p }' ${prefs} \
        | podman exec -i qbittorrent curl -fsS -X POST "$API/app/setPreferences" --data-urlencode json@-
      echo "qBittorrent configured: direct peer traffic, DHT/PEX/LSD on, ${toString activeDownloadsMax} active downloads"
    '';
  };

  systemd.services.podman-qbittorrent.unitConfig.RequiresMountsFor = [ incompleteDir ];

  systemd.tmpfiles.rules = [
    "d ${configDir} 0750 ${appId} ${appId} -"
    "d ${incompleteDir} 0750 ${appId} ${appId} -"
  ];

  # leased port changes, so match on public source; iptables host, extraInputRules would be nftables-only
  networking.firewall.extraCommands = ''
    iptables -N homelab-peers 2>/dev/null || iptables -F homelab-peers
    ${lib.concatMapStrings (s: ''
      iptables -A homelab-peers -s ${s} -j RETURN
    '') (net.privateRanges ++ [ "127.0.0.0/8" ])}
    iptables -A homelab-peers -p tcp --dport ${peerPorts} -j nixos-fw-accept
    iptables -A homelab-peers -p udp --dport ${peerPorts} -j nixos-fw-accept
    iptables -A nixos-fw -j homelab-peers
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -j homelab-peers 2>/dev/null || true
    iptables -F homelab-peers 2>/dev/null || true
    iptables -X homelab-peers 2>/dev/null || true
  '';

  # uid 1000 in the container binds the webui port
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = route.port;
}
