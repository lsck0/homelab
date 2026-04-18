{ ... }: {
  networking.hostName = "vm-203";
  virtualisation.oci-containers.containers.share = {
    image = "lscr.io/linuxserver/nextcloud:latest";
    ports = [ "80:80" ];
    volumes = [ "/var/lib/share:/config" ];
  };
  networking.firewall.allowedTCPPorts = [ 80 ];
}
