{ nasMount, ... }: {
  networking.hostName = "vm-202";
  fileSystems = nasMount "/var/lib/shlink" "shlink";

  virtualisation.oci-containers.containers.shlink = {
    image = "shlinkio/shlink:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/shlink:/etc/shlink/data" ];
    environment = {
      DEFAULT_DOMAIN = "shlink.lsck0.dev";
      ADDITIONAL_DOMAINS = "shlink.external";
      IS_HTTPS_ENABLED = "true";
      DB_DRIVER = "sqlite";
      TIMEZONE = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/shlink 0750 1001 1001 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
