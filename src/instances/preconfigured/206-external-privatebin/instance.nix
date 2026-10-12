# encrypted pastebin
{ ... }: {
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
      off = {
        sso = "public pastebin";
        cloudflare = "anubis fronts it at the edge";
        bodyLimit = "privatebin caps pastes itself";
      };
    };
  };

  shares = {
    "data/privatebin" = { };
  };
}
