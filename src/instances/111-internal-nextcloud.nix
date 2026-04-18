{ pkgs, config, ... }: {
  networking.hostName = "vm-111";

  sops.secrets.nextcloud-admin-pass.owner = "nextcloud";

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [{
      name = "nextcloud";
      ensureDBOwnership = true;
    }];
  };

  services.nextcloud = {
    enable = true;
    hostName = "cloud.internal.local";
    config.dbtype = "pgsql";
    config.dbhost = "/run/postgresql";
    config.dbname = "nextcloud";
    config.adminpassFile = config.sops.secrets.nextcloud-admin-pass.path;
    package = pkgs.nextcloud33;
    database.createLocally = true;
  };

  systemd.services."nextcloud-setup" = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
