{ config, pkgs, nasMount, ... }: {
  networking.hostName = "vm-126";

  fileSystems = nasMount "/var/lib/huginn" "huginn"
    // nasMount "/var/lib/postgresql" "huginn-db";

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    ensureDatabases = [ "huginn" ];
    ensureUsers = [{
      name = "huginn";
      ensureDBOwnership = true;
      ensureClauses.createdb = true;
    }];
    authentication = ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
      # all databases, not just huginn: the entrypoint runs `db:create`, which
      # connects to the `postgres` maintenance database first and was refused
      # with "no pg_hba.conf entry for ... database \"postgres\"".
      host all huginn 10.88.0.0/16 trust
    '';
  };

  virtualisation.oci-containers.containers.huginn = {
    image = "ghcr.io/huginn/huginn:f2cc19148df9a4785d789d30f0b10d1d9c2dae10";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/huginn:/var/lib/huginn" ];
    environmentFiles = [ "/var/lib/huginn/seed.env" ];
    environment = {
      DOMAIN = "huginn.lsck0.dev";
      DATABASE_ADAPTER = "postgresql";
      DATABASE_HOST = "10.88.0.1";
      DATABASE_PORT = "5432";
      DATABASE_NAME = "huginn";
      DATABASE_USERNAME = "huginn";
      SEED_USERNAME = "akadmin";
      REQUIRE_CONFIRMED_EMAIL = "false";
    };
  };

  # SEED_PASSWORD for the first admin, generated once
  systemd.services.huginn-seed = {
    before = [ "podman-huginn.service" ];
    requiredBy = [ "podman-huginn.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      f=/var/lib/huginn/seed.env
      [ -s $f ] || echo "SEED_PASSWORD=$(openssl rand -hex 16)" > $f
      chmod 600 $f
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/huginn 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
  # Postgres only for the container (podman bridge), not the subnet
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ 5432 ];

  # /var/lib/postgresql is a live data directory on the NAS: Kopia's file copy of
  # one is not a backup (it can catch a checkpoint mid-flight). pg_dumpall runs
  # through Postgres itself and produces something restorable.
  homelab.dbBackup.databases.huginn = {
    command = "${config.services.postgresql.package}/bin/pg_dumpall -U postgres --clean --if-exists";
    path = [ config.services.postgresql.package ];
  };
  systemd.services.db-backup-huginn = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig.User = "postgres";
  };

}
