# music streaming (Subsonic API)
{ id, config, profiles, ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    kind.lxc = "an existing lxc with local state; recreating it as a vm needs a data migration";
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  grants = [ {
    from = [ "internal" "lan" "wireguard" ];
    tcp = [ config.services.navidrome.port ];
    why = "its direct subsonic clients, not yet named: the lab, the house and the owner's devices";
  } ];

  tokens = [ "navidrome-salt" "navidrome-token" "navidrome-user" ];

  # the admin, created once by the setup
  secrets = { navidrome-pass = "guardsData:hex:16"; };

  # on demand: its zone's ingress wakes it on a request
  idle = { stopAfter = "30m"; };

  services = {
    navidrome = {
      host = "music";
      port = 80;
      homepage = { description = "Music"; group = "Media"; icon = "navidrome"; };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "bulk/media/music".readOnly = true;
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/navidrome".localState = true;
  };
}
