{ ... }: {
  networking.hostName = "vm-128";

  # indexer manager. Indexers and the app connections to Radarr/Sonarr/Lidarr/
  # Bookshelf are created by the *arr wiring on vm-132.
  homelab.servarr.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:latest";
    port = 9696;
  };
}
