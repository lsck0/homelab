# music streaming (Subsonic API)
{
  id,
  config,
  profiles,
  ...
}:
{
  vm = {
    # parked so atm gets its 10 GiB unballooned; "on" brings it back
    power = "off";
    bootPhase = "media";
    needs = [
      "containers"
      "nfs"
    ];
  };

  grants = [
    {
      from = [
        "operator"
        "lan"
        "wireguard"
      ];
      tcp = [ config.services.navidrome.port ];
      why = "its direct subsonic clients: hermes, the house and the owner's devices";
    }
  ];

  tokens = [
    "navidrome-salt"
    "navidrome-token"
    "navidrome-user"
  ];

  # the admin, created once by the setup
  secrets = {
    navidrome-pass = "guardsData:hex:16";
  };

  # on demand: its zone's ingress wakes it on a request
  idle = {
    stopAfter = "30m";
  };

  services = {
    navidrome = {
      host = "music";
      port = 80;
      homepage = {
        description = "Music";
        group = "Media";
        icon = "navidrome";
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "bulk/media/music".readOnly = true;
    "data/db-dumps/vm-${id}" = {
      mode = "0700";
    };
    "data/navidrome".localState = true;
  };
}
