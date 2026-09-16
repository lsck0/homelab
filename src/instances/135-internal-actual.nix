{ nasMount, ... }: {
  networking.hostName = "vm-135";

  # Actual Budget — self-hosted finance. Single container, sqlite under the NAS
  # tree so it is backed up. Behind Authelia at budget.lsck0.dev.
  fileSystems = nasMount "/var/lib/actual" "actual";

  virtualisation.oci-containers.containers.actual = {
    image = "docker.io/actualbudget/actual-server:latest";
    ports = [ "80:5006" ];
    volumes = [ "/var/lib/actual:/data" ];
    environment = {
      ACTUAL_PORT = "5006";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/actual 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
