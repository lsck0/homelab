{ ... }: {
  networking.hostName = "vm-114";

  virtualisation.oci-containers.containers.huginn = {
    image = "ghcr.io/huginn/huginn:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/huginn:/var/lib/huginn" ];
    environment = {
      DOMAIN = "huginn.local";
      DATABASE_ADAPTER = "sqlite3";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
