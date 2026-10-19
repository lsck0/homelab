# build cache: redis for sccache
{
  config,
  pkgs,
  instance,
  ...
}:
{
  sops.secrets.sccache-redis-pass = { };

  services.redis.servers.sccache = {
    enable = true;
    inherit (instance.config.services.sccache) port;
    bind = "0.0.0.0";
    requirePassFile = config.sops.secrets.sccache-redis-pass.path;
    settings = {
      protected-mode = "no";
      maxmemory = "256mb";
      maxmemory-policy = "allkeys-lru";
      # a cache: losing it on restart costs one cold build, persisting it costs a write per job
      appendonly = "no";
    };
  };
  environment.systemPackages = [ pkgs.sccache ];
}
