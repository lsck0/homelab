# build caches: attic (nix) + sccache redis
{ lib, config, profiles, ... }: {
  vm = {
    bootPhase = "dev";
    # 63 MiB peak over 7d; redis caps itself at 256mb
    memoryMiB = 512;
    diskGiB = 40;
  };

  grants = [
    { from = [ "ci" ]; tcp = [ config.services.sccache.port ]; why = "the forgejo runner's ci jobs share sccache (SCCACHE_REDIS)"; }
  ];

  services = {
    # redis, lab-only: guarded, probed and named in the lab's dns at this guest
    # redis at its protocol's default port
    sccache = { protocol = "tcp"; port = 6379; on = [ "guard" "probe" ] ++ profiles.observed; };
    attic = {
      port = 8080;
      # the lab's nix clients only, every host direct with attic tokens; nar uploads the waf rules misread; no web ui
      on = lib.subtractLists [ "sso" "waf" "bodyLimit" "guard" "internet" "cloudflare" ] profiles.hardenedInternal
        ++ [ "probe" ] ++ profiles.observed;
    };
  };

  secrets = { attic-server-token = "manual"; };
}
