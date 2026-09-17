{ ... }: {
  networking.hostName = "vm-129";

  # movies -> /data/media/movies. Download client, root folder and Prowlarr sync
  # are wired by vm-132.
  homelab.servarr.radarr = {
    image = "lscr.io/linuxserver/radarr:latest";
    port = 7878;
  };
}
