{ config, nasMount, ... }: {
  networking.hostName = "vm-123";

  fileSystems = nasMount "/var/lib/postgresql" "wikijs-db";

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    ensureDatabases = [ "wikijs" ];
    ensureUsers = [{
      name = "wikijs";
      ensureDBOwnership = true;
    }];
    authentication = ''
      host wikijs wikijs 10.88.0.0/16 trust
    '';
  };

  virtualisation.oci-containers.containers.wikijs = {
    image = "ghcr.io/requarks/wiki:2.5.314";
    ports = [ "80:3000" ];
    environment = {
      DB_TYPE = "postgres";
      DB_HOST = "10.88.0.1";
      DB_PORT = "5432";
      DB_USER = "wikijs";
      DB_NAME = "wikijs";
      DB_PASS = "wikijs";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
  # Postgres only for the container (podman bridge), not the subnet
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ 5432 ];

  # /var/lib/postgresql is a live data directory on the NAS: Kopia's file copy of
  # one is not a backup (it can catch a checkpoint mid-flight). pg_dumpall runs
  # through Postgres itself and produces something restorable.
  homelab.dbBackup.databases.wikijs = {
    command = "${config.services.postgresql.package}/bin/pg_dumpall -U postgres --clean --if-exists";
    path = [ config.services.postgresql.package ];
  };
  systemd.services.db-backup-wikijs = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig.User = "postgres";
  };

}
