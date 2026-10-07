# torrent client, egress through the router's vpn exit
{ ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
    # unfinished downloads: the size caps what torrents can take of the nvme pool
    disks = [ { sizeGiB = 150; } ];
  };

  tokens = [ "qbittorrent-pass" "qbittorrent-user" ];

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
          tokens = { password = "qbittorrent-pass"; username = "qbittorrent-user"; };
          type = "qbittorrent";
        };
      };
      off = { bodyLimit = "torrent file uploads"; };
    };
  };
}
