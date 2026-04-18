{ ... }: {
  networking.hostName = "vm-108";

  virtualisation.oci-containers.containers.homepage = {
    image = "ghcr.io/gethomepage/homepage:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/homepage:/app/config" ];
    environment = {
      HOMEPAGE_ALLOWED_HOSTS = "home.internal.local,home.lsck0.dev";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homepage 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
