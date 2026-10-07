# music streaming (Subsonic API)
{ ... }: {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    kind.lxc = "pending migration, see the restructure report";
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  tokens = [ "navidrome-pass" "navidrome-salt" "navidrome-token" "navidrome-user" ];

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
}
