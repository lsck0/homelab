# build caches: attic (nix substituter) + redis for sccache
{ config, pkgs, ... }: {
  networking.hostName = "vm-110";


  # nix binary cache for every vm and the forgejo runner
  sops.secrets.attic-server-token = {};
  sops.templates."atticd.env".content = ''
    ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=${config.sops.placeholder.attic-server-token}
  '';

  services.atticd = {
    enable = true;
    environmentFile = config.sops.templates."atticd.env".path;
    settings = {
      listen = "0.0.0.0:8080";
      database.url = "sqlite:///var/lib/atticd/db.sqlite?mode=rwc";
      # under atticd's StateDirectory
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };
      # dedupe hard, store paths overlap a lot
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
      # atticd keeps everything by default; a path unused for 30 days is a stale generation, and a miss costs one
      # rebuild. caches with their own `attic cache configure --retention-period` keep theirs.
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "30 days";
      };
    };
  };

  sops.secrets.sccache-redis-pass = { };

  services.redis.servers.sccache = {
    enable = true;
    port = 6379;
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
  environment.systemPackages = [ pkgs.attic-client pkgs.sccache ];

  networking.firewall.allowedTCPPorts = [ 8080 6379 ];
  # password plus firewall: only the ci hosts that set SCCACHE_REDIS (forgejo 115, github 117) reach it
  homelab.ingressOnly.ports = [ 6379 ];
  homelab.ingressOnly.portSources."6379" = [ "10.100.0.115/32" "10.100.0.117/32" ];
}
