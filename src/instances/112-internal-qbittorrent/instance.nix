# torrent client, egress through the router's vpn exit
{ ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
    # unfinished downloads: the size caps what torrents can take of the nvme pool
    disks = [ { sizeGiB = 150; } ];
  };

  tokens = [ "qbittorrent-user" ];

  grants = [ {
    from = [ "router" "104" "114" "130" ];
    tcp = [ 80 ];
    why = "the webui api without its login: the router's protonvpn-port sets the leased port, terminal stats, hermes, the arrs' download client";
  } ];

  shares = {
    "data/qbittorrent" = { };
    bulk = { };
  };

  # peers find it through the exit's forwarded port
  egress = { via = "vpn"; inbound = true; };

  services = {
    qbittorrent = {
      host = "torrent";
      port = 80;
      homepage = {
        description = "Downloads (VPN)";
        group = "Media";
        icon = "qbittorrent";
        name = "qBittorrent";
        widget = {
          tokens = { username = "qbittorrent-user"; };
          secrets = { password = "qbittorrent-pass"; };
          type = "qbittorrent";
        };
      };
      off = { bodyLimit = "torrent file uploads"; };
    };
  };
}
