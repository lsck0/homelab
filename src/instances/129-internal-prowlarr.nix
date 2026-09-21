{ ... }: {
  networking.hostName = "vm-129";

  # indexer manager. Indexers and the app connections to Radarr/Sonarr/Lidarr/
  # Bookshelf are created by the *arr wiring on vm-133.
  homelab.servarr.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161";
    port = 9696;
  };
}
