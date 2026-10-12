# encrypted pastebin
{ lib, profiles, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
  };

  idle = { stopAfter = "30m"; };

  services = {
    privatebin = {
      host = "paste";
      port = 80;
      homepage = { group = "Public"; icon = "privatebin"; name = "PrivateBin"; };
      # anubis fronts it at the edge; privatebin caps pastes itself
      on = lib.subtractLists [ "cloudflare" "bodyLimit" ] profiles.hardenedExternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/privatebin" = { };
  };
}
