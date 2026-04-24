{ nasMount, ... }: {
  networking.hostName = "vm-202";

  fileSystems = nasMount "/var/lib/searxng" "searxng";

  virtualisation.oci-containers.containers.searxng = {
    image = "searxng/searxng:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/searxng:/etc/searxng" ];
    environment = {
      SEARXNG_BASE_URL = "https://search.lsck0.dev/";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
