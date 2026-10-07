# build caches: attic (nix substituter) + redis for sccache
{ config, lib, pkgs, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  atticPort = catalog.internal.attic.port;
  stateDir = "/var/lib/atticd";
in {
  # nix binary cache for every vm and the forgejo runner
  sops.secrets.attic-server-token = {};
  sops.templates."atticd.env".content = ''
    ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=${config.sops.placeholder.attic-server-token}
  '';

  services.atticd = {
    enable = true;
    environmentFile = config.sops.templates."atticd.env".path;
    settings = {
      listen = "0.0.0.0:${toString atticPort}";
      # under atticd's StateDirectory
      database.url = "sqlite://${stateDir}/db.sqlite?mode=rwc";
      storage = {
        type = "local";
        path = "${stateDir}/storage";
      };
      # dedupe hard, store paths overlap a lot
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
      # atticd keeps everything by default; a path unused for 30 days is a stale generation and a miss costs one rebuild
      garbage-collection = {
        interval = "12 hours";
        default-retention-period = "30 days";
      };
    };
  };

  sops.secrets.sccache-redis-pass = { };

  services.redis.servers.sccache = {
    enable = true;
    port = net.ports.redis;
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

  networking.firewall.allowedTCPPorts = [ net.ports.redis ];
  # password plus guard: only the grants in instance.nix reach it
  homelab.ingressOnly.ports = [ net.ports.redis ];
}
