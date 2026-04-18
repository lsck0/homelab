{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-120";

  fileSystems = nasMount "/var/lib/postgresql" "wikijs-db";

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "wikijs" ];
    ensureUsers = [{
      name = "wikijs";
      ensureDBOwnership = true;
    }];
  };

  virtualisation.oci-containers.containers.wikijs = {
    image = "ghcr.io/requarks/wiki:2";
    ports = [ "80:3000" ];
    environment = {
      DB_TYPE = "postgres";
      DB_HOST = "10.100.0.120";
      DB_PORT = "5432";
      DB_USER = "wikijs";
      DB_NAME = "wikijs";
      DB_PASS = "wikijs";
    };
  };

  # Allow container to reach host PostgreSQL
  services.postgresql.enableTCPIP = true;
  services.postgresql.authentication = ''
    host wikijs wikijs 10.100.0.120/32 trust
  '';

  networking.firewall.allowedTCPPorts = [ 80 5432 ];
}
