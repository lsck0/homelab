{ config, pkgs, lib, nasMount, nasPath, retry, ... }:
let
  # hosts that may use the WebUI API without a login: internal Traefik (itself
  # behind Authelia), the *arr VMs, the wiring VM and Hermes. Explicit /32s, so
  # an arbitrary LAN host cannot rewrite download paths across the NFS mounts.
  # 104 is the terminal dashboard collector (transfer rates and torrent list).
  apiClients = map (id: "10.100.0.${toString id}/32") [ 100 104 114 130 131 133 135 136 ];

  # Peer traffic goes out directly. It used to go through the Tor SOCKS5
  # gateway on vm-113, and that is simply not a thing BitTorrent can do:
  # SOCKS5 over Tor carries TCP only, so every udp:// tracker announce came
  # back "Permission denied", DHT and uTP were impossible, and exit nodes drop
  # the peer protocol. The symptom was a torrent that knew about nine seeds and
  # held zero connections to any of them, with connection_status "firewalled".
  #
  # The indexer side is unaffected: Prowlarr still searches through the same
  # Tor gateway (a Socks5 indexer proxy, configured by arr-wire.sh), which is
  # plain HTTP and works fine. Searches stay private; the swarm sees this
  # WAN address.
  prefs = pkgs.writeText "qbittorrent-prefs.json" (builtins.toJSON {
    proxy_type = "None";
    proxy_bittorrent = false;
    proxy_peer_connections = false;
    proxy_misc = false;
    proxy_rss = false;
    # anonymous_mode suppresses the client fingerprint and the IP in tracker
    # announces. Without a proxy it buys little and some private trackers
    # refuse it, but it costs nothing on public ones.
    anonymous_mode = false;
    save_path = "/data/torrents";
    bypass_auth_subnet_whitelist_enabled = true;
    bypass_auth_subnet_whitelist = lib.concatStringsSep ", " apiClients;
    # back on: these are how a swarm is actually found. They were off only
    # because UDP cannot cross a SOCKS5 proxy.
    dht = true;
    pex = true;
    lsd = true;
    # The WebUI has to answer on 80, because that is where the *arr, Traefik,
    # Homepage and the dashboard collector all look, and with host networking
    # there is no publish to remap it. Binding it as the container's
    # unprivileged user needs the sysctl below.
    web_ui_port = 80;
    # The listen port is whatever Proton's NAT-PMP lease currently says;
    # protonvpn-port.service overwrites it. 6881 is only the value the client
    # starts on before the first lease arrives.
    listen_port = 6881;
    random_port = false;
    upnp = false;
    queueing_enabled = true;
    max_active_downloads = 5;
    # One torrent seeds at a time. Upstream is the scarce direction on a
    # domestic line, and a seed saturating it makes everything else in the
    # flat feel broken - a video call before a download.
    max_active_uploads = 1;
    # downloads plus the one upload slot, so a full download queue never
    # starves seeding of its slot.
    max_active_torrents = 6;
    dont_count_slow_torrents = true;
  });
in {
  networking.hostName = "vm-112";

  # ── egress ──────────────────────────────────────────────────────────────
  # Everything this VM sends leaves through Proton, and there is no default
  # route when the tunnel is down, so a drop means no traffic rather than
  # traffic from the house address. The LAN stays off the tunnel: the NFS
  # mounts, the *arr reaching the WebUI, and ssh all live on 10.100.0.0/24,
  # which the kernel routes on-link.
  sops.secrets.protonvpn-private-key = {};
  homelab.vpn = {
    enable = true;
    privateKeyFile = config.sops.secrets.protonvpn-private-key.path;
    address = "10.2.0.2/32";
    publicKey = "36G8+pInNcPK9F1TpHglWs9Pk5uJOY9o8SCNrCBgvHE=";
    # CH#684. An address and not a name, because DNS is inside the tunnel.
    endpoint = "89.222.96.158:51820";
    dns = "10.2.0.1";
    lanGateway = "10.100.0.1";
    # Everything that must not be answered through the tunnel. The VM's own
    # /24 is on-link and needs no entry; these are reached through the router
    # and every one of them is a way in. Leaving 192.168.178.0/24 out of this
    # list took the VM off the network: ssh from a workstation on the house
    # LAN still arrived, and the replies went into Proton.
    lanRoutes = [
      "192.168.178.0/24"  # the house LAN, and the Proxmox host
      "10.200.0.0/24"     # the DMZ
      "10.0.0.0/24"       # the router's WireGuard clients
    ];
  };

  # Proton's forwarded port is leased for 60 seconds at a time and changes
  # when the lease lapses, so it has to be renewed and handed to the client
  # rather than configured once.
  systemd.services.protonvpn-port = {
    description = "Renew the Proton forwarded port and give it to qBittorrent";
    after = [ "wireguard-wg0.service" "podman-qbittorrent.service" ];
    path = [ pkgs.libnatpmp pkgs.podman pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "protonvpn";
    };
    script = "exec ${pkgs.bash}/bin/bash ${../scripts/protonvpn-port.sh}";
  };

  systemd.timers.protonvpn-port = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90s";
      OnUnitActiveSec = "45s";
      AccuracySec = "5s";
    };
  };

  fileSystems = nasMount "/var/lib/qbittorrent" "qbittorrent"
    // nasPath "/data/torrents" "torrents"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # Host networking, not a published port. Proton's NAT-PMP always maps the
  # public port to the same private port and will not grant a chosen one, so
  # the client has to bind whatever it is leased - which a fixed "6881:6881"
  # publish cannot follow. The symptom was a client that downloaded fine and
  # was reachable by nobody: Proton forwarded 49649 to the VM and the only
  # listener was conmon on 6881.
  virtualisation.oci-containers.containers.qbittorrent = {
    image = "lscr.io/linuxserver/qbittorrent:5.2.3_v2.0.14-ls476";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/qbittorrent:/config"
      "/data/torrents:/data/torrents"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
      WEBUI_PORT = "80";
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
      # run curl inside the container: only there is the request really from
      # loopback (WebUI\LocalHostAuth=false). With host networking that is
      # the same loopback as the VM's, but podman exec keeps this working
      # whichever way the container is attached.
      curl() { podman exec qbittorrent curl "$@"; }
      ${retry} 60 2 podman exec qbittorrent curl -fsS "$API/app/version"

      # WebUI login for everything off the whitelist. Homepage and the *arr
      # download clients read it from the token files.
      T=/var/lib/homepage-tokens
      [ -s $T/qbittorrent-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/qbittorrent-pass.token
      echo -n admin > $T/qbittorrent-user.token

      prefs=$(jq -c --rawfile p $T/qbittorrent-pass.token '. + { web_ui_username: "admin", web_ui_password: $p }' ${prefs})
      curl -fsS -X POST "$API/app/setPreferences" --data-urlencode "json=$prefs"
      echo "qBittorrent configured: direct peer traffic, DHT/PEX/LSD on, 5 active downloads"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0750 1000 1000 -"
  ];

  # The peer port changes with every Proton lease, so it cannot be listed.
  # Trusting wg0 is the honest way to say it: the only thing that reaches this
  # VM over that interface is Proton, and Proton only forwards the one port it
  # leased. 6881 is gone from the LAN side with the router's forward.
  networking.firewall.trustedInterfaces = [ "wg0" ];
  networking.firewall.allowedTCPPorts = [ 80 ];

  # qBittorrent runs as uid 1000 inside the container and, sharing the host's
  # network namespace, has to bind 80 itself.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  # the WebUI skips its login for the whitelisted API clients, so the port
  # itself must not be reachable from anywhere else. 6881 (peer traffic) stays
  # open. apiClients is the same list the whitelist uses.
  homelab.ingressOnly = {
    ports = [ 80 ];
    extraSources = apiClients;
  };
}
