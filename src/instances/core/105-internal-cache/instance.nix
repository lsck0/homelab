# build cache: sccache redis
{ config, profiles, ... }:
{
  vm = {
    bootPhase = "dev";
    # 63 MiB peak over 7d; redis caps itself at 256mb
    memoryMiB = 512;
    diskGiB = 40;
  };

  grants = [
    {
      from = [ "ci" ];
      tcp = [ config.services.sccache.port ];
      why = "the forgejo runner's ci jobs share sccache (SCCACHE_REDIS)";
    }
  ];

  services = {
    # redis, lab-only: guarded, probed and named in the lab's dns at this guest
    sccache = {
      protocol = "tcp";
      port = 6379;
      on = [
        "guard"
        "probe"
      ]
      ++ profiles.observed;
    };
  };
}
