{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-116";

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
    image = "ghcr.io/requarks/wiki:2";
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

  networking.firewall.allowedTCPPorts = [ 80 5432 ];
}
