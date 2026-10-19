# media requests: movies, series, anime (-> Radarr/Sonarr)
{ profiles, ... }:
let
  port = 80;
in
{
  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "media";
    needs = [
      "containers"
      "nfs"
    ];
    # a node process beside the vm's own kernel and container runtime
    memoryMiB = 1024;
    # image plus local state filled 8 GiB to 80%, and a vm keeps its nix store beside them
    diskGiB = 16;
  };

  tokens = [ "jellyseerr-key" ];

  grants = [
    {
      from = [
        "operator"
        "121"
      ];
      tcp = [ port ];
      why = "hermes and arr-wire call its api directly";
    }
  ];

  idle = {
    stopAfter = "30m";
  };

  services = {
    jellyseerr = {
      host = "requests";
      inherit port;
      guest = true;
      homepage = {
        description = "Requests";
        group = "Media";
        icon = "jellyseerr";
        widget = {
          tokens = {
            key = "jellyseerr-key";
          };
          type = "jellyseerr";
        };
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/jellyseerr".localState = true;
  };
}
