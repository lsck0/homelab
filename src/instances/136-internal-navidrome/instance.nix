# music streaming (Subsonic API)
{ id, ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    kind.lxc = "pending migration, see the restructure report";
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

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
      off.guard = "open to the lab until its direct clients are grants";
    };
  };

  shares = {
    "bulk/media/music".readOnly = true;
    "data/db-dumps/vm-${id}" = { mode = "0700"; };
    "data/navidrome" = { };
  };
}
