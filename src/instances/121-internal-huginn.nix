{ config, nasMount, ... }: {
  networking.hostName = "vm-121";

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
      host all all 10.0.0.0/8 trust
    '';
  };

  virtualisation.oci-containers.containers.huginn = {
    image = "ghcr.io/huginn/huginn:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/huginn:/var/lib/huginn" ];
    environment = {
      DOMAIN = "huginn.internal";
      DATABASE_ADAPTER = "postgresql";
      DATABASE_HOST = "10.100.0.121";
      DATABASE_PORT = "5432";
      DATABASE_NAME = "huginn";
      DATABASE_USERNAME = "huginn";
      SEED_USERNAME = "akadmin";
      SEED_PASSWORD = "changeme123!";
      REQUIRE_CONFIRMED_EMAIL = "false";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/huginn 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5432 ];
}
