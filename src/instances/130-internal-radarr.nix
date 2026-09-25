{ ... }: {
  networking.hostName = "vm-130";

  # movies -> /data/media/movies.
  homelab.servarr.radarr = {
    image = "lscr.io/linuxserver/radarr:6.4.4.10685-ls317";
    port = 7878;
  };
}
