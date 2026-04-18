{ ... }: {
  networking.hostName = "vm-201";
  virtualisation.oci-containers.containers.shlink = {
    image = "shlinkio/shlink:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/shlink:/etc/shlink/data" ];
    environment = {
      DEFAULT_DOMAIN = "shlink.lsck0.dev";
      ADDITIONAL_DOMAINS = "shlink.external.local";
      IS_HTTPS_ENABLED = "true";
      GEOLITE2_LICENSE_KEY = ""; # Optional but prevents some errors
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/shlink 0750 1001 1001 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
