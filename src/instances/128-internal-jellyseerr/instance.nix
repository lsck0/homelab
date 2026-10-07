# media requests: movies, series, anime (-> Radarr/Sonarr)
{ ... }: let port = 80; in {
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

  grants = [
    { from = [ "114" "130" "134" ]; tcp = [ port ]; why = "hermes, arr-wire and janitorr call its api directly"; }
  ];

  idle = { stopAfter = "30m"; };

  services = {
    jellyseerr = {
      host = "requests";
      inherit port;
      guest = true;
      homepage = {
        description = "Requests";
        group = "Media";
        icon = "jellyseerr";
        widget = { tokens = { key = "jellyseerr-key"; }; type = "jellyseerr"; };
      };
    };
  };
}
