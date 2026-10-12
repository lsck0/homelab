# public file sharing
{ lib, profiles, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
  };

  idle = { stopAfter = "30m"; };

  services = {
    share = {
      port = 80;
      homepage = { group = "Public"; icon = "pingvin-share"; };
      # anubis fronts it at the edge; file uploads
      on = lib.subtractLists [ "cloudflare" "bodyLimit" ] profiles.hardenedExternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/share" = { };
  };
}
