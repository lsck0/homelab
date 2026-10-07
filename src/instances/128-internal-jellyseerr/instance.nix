# media requests: movies, series, anime (-> Radarr/Sonarr)
{ ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    kind.lxc = "an existing lxc with local state; recreating it as a vm needs a data migration";
    memoryMiB = 1024;
    # image plus local state filled 8 GiB to 80%
    diskGiB = 12;
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  tokens = [ "jellyseerr-key" ];

  idle = { stopAfter = "30m"; };

  services = {
    jellyseerr = {
      host = "requests";
      port = 80;
      guest = true;
      homepage = {
        description = "Requests";
        group = "Media";
        icon = "jellyseerr";
        widget = { tokens = { key = "jellyseerr-key"; }; type = "jellyseerr"; };
      };
      off.guard = "open to the lab until its direct clients are grants";
    };
  };
}
