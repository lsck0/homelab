# build caches: attic (nix) + sccache redis
{ config, ... }: {
  vm = {
    bootPhase = "dev";
    # 63 MiB peak over 7d; redis caps itself at 256mb
    memoryMiB = 512;
    diskGiB = 40;
  };

  grants = [
    { from = [ "117" ]; tcp = [ config.services.sccache.port ]; why = "the forgejo runner's ci jobs share sccache (SCCACHE_REDIS)"; }
  ];

  services = {
    # sccache speaks redis: a lab-only tcp service at redis's own port
    sccache = {
      protocol = "tcp";
      port = 6379;
      off.homepage = "no web ui";
    };
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
