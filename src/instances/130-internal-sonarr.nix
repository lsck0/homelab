{ ... }: {
  networking.hostName = "vm-130";

  # series -> /data/media/tv, anime (series type "anime") -> /data/media/anime.
  # download client, root folders and Prowlarr sync are wired by vm-132.
  homelab.servarr.sonarr = {
    image = "lscr.io/linuxserver/sonarr:latest";
    port = 8989;
  };
}
