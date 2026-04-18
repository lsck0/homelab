{ config, ... }: {
  networking.hostName = "vm-114";

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "huginn" ];
    ensureUsers = [{
      name = "huginn";
      ensureDBOwnership = true;
    }];
    authentication = ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
    '';
  };

  virtualisation.oci-containers.containers.huginn = {
    image = "ghcr.io/huginn/huginn:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/huginn:/var/lib/huginn" ];
    environment = {
      DOMAIN = "huginn.local";
      DATABASE_ADAPTER = "postgresql";
      DATABASE_HOST = "10.100.0.114";
      DATABASE_PORT = "5432";
      DATABASE_NAME = "huginn";
      DATABASE_USERNAME = "huginn";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/huginn 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5432 ];
}
