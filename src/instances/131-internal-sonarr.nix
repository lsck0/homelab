{ ... }: {
  networking.hostName = "vm-131";

  # series -> /data/media/tv, anime (series type "anime") -> /data/media/anime. download
  homelab.servarr.sonarr = {
    image = "lscr.io/linuxserver/sonarr:4.0.20.3014-ls325";
    port = 8989;
  };
}
