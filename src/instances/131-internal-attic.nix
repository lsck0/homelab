{ config, nasMount, ... }: {
  networking.hostName = "vm-131";

  # Attic: a Nix binary cache shared across every VM and the Forgejo runner, so
  # a closure built once (during a deploy) is fetched, not rebuilt, everywhere
  # else. sccache only covers Rust; this covers all Nix builds.
  #
  # Chunks live on the NAS (large, and worth backing up); the sqlite metadata
  # db stays on local disk to avoid NFS locking issues.
  fileSystems = nasMount "/var/lib/atticd/storage" "attic";

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
      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };
      # Deduplicate aggressively — Nix store paths share a lot.
      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/atticd 0750 atticd atticd -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
