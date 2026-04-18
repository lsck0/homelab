{ ... }: {
  networking.hostName = "vm-115";

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:stable";
    ports = [ "80:8123" ];
    volumes = [ "/var/lib/homeassistant:/config" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
