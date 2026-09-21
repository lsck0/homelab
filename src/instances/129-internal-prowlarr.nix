{ pkgs, ... }: {
  networking.hostName = "vm-129";

  # indexer manager. Indexers and the app connections to Radarr/Sonarr/Lidarr/
  # Bookshelf are created by the *arr wiring on vm-133.
  homelab.servarr.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161";
    port = 9696;
  };

  # Half the useful public trackers sit behind Cloudflare's bot check and
  # answer Prowlarr with "blocked by CloudFlare Protection": 1337x, EZTV,
  # kickasstorrents, ExtraTorrent and Uindex all failed to add for that reason.
  # FlareSolverr drives a headless browser through the challenge and hands the
  # cookie back, which is the only way those indexers work at all.
  #
  # Bound to the podman bridge, not the host address: Prowlarr runs in its own
  # bridged container, so 127.0.0.1 there is not this host. 10.88.0.1 is the
  # bridge gateway, reachable from sibling containers and from nowhere off the
  # VM, which matters because FlareSolverr is an unauthenticated
  # browser-as-a-service.
  virtualisation.oci-containers.containers.flaresolverr = {
    image = "ghcr.io/flaresolverr/flaresolverr:v3.4.2";
    ports = [ "10.88.0.1:8191:8191" ];
    environment = {
      LOG_LEVEL = "warning";
      TZ = "Europe/Berlin";
    };
  };
}
