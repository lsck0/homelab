{ pkgs, ... }: {
  networking.hostName = "vm-117";

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
      DB_HOST = "10.100.0.117";
      DB_PORT = "5432";
      DB_USER = "wikijs";
      DB_NAME = "wikijs";
      DB_PASS = "wikijs";
    };
  };

  # Allow container to reach host PostgreSQL
  services.postgresql.enableTCPIP = true;
  services.postgresql.authentication = ''
    host wikijs wikijs 10.100.0.117/32 trust
    host wikijs wikijs 10.88.0.0/16 trust
  '';

  networking.firewall.allowedTCPPorts = [ 80 ];
}
