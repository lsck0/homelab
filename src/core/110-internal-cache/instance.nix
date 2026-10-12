# build caches: attic (nix) + sccache redis
{ config, ... }: {
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
    sccache = { protocol = "tcp"; port = 6379; off.homepage = "a cache, no page"; };
    attic = {
      port = 8080;
      off = {
        guard = "every lab host substitutes from it directly";
        sso = "nix clients use attic tokens";
        anubis = "nix clients run no proof of work";
        waf = "nar uploads the rules misread";
        internet = "only the lab's nix clients";
        homepage = "no web ui";
        bodyLimit = "nar uploads";
      };
    };
  };

  secrets = { attic-server-token = "manual"; };
}
