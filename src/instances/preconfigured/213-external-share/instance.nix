# public file sharing
{ lib, profiles, ... }:
{
  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "public";
    needs = [
      "containers"
      "nfs"
    ];
    # 476 MiB peak over 35d
    memoryMiB = 768;
  };

  idle = {
    stopAfter = "30m";
  };

  services = {
    share = {
      port = 80;
      homepage = {
        group = "Public";
        icon = "pingvin-share";
      };
      # anubis fronts it at the edge; file uploads
      on = lib.subtractLists [ "cloudflare" "bodyLimit" ] profiles.hardenedExternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/share" = { };
  };
}
