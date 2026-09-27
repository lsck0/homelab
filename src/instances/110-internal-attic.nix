{ config, pkgs, ... }: {
  networking.hostName = "vm-110";

  # attic client to create the cache and read its key
  environment.systemPackages = [ pkgs.attic-client ];

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
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
