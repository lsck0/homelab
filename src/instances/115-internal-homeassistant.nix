{ ... }: {
  networking.hostName = "vm-115";

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:stable";
    ports = [ "80:8123" ];
    volumes = [ "/var/lib/homeassistant:/config" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
