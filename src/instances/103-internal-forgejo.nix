{ ... }: {
  networking.hostName = "vm-103";

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo:7";
    ports = [ "80:3000" "2222:22" ];
    volumes = [ "/var/lib/forgejo:/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 2222 ];
}
