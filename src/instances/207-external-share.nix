{ nasMount, ... }: {
  networking.hostName = "vm-207";
  fileSystems = nasMount "/var/lib/pingvin-share" "share";

  virtualisation.oci-containers.containers.share = {
    image = "stonith404/pingvin-share:v1.13.0";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/pingvin-share:/opt/app/backend/data" ];
    # ~220 MiB: vm 30d peak 469 minus the idle base
    extraOptions = [ "--memory=384m" ];
    environment = {
      TRUST_PROXY = "true";
      APP_URL = "https://share.lsck0.dev";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/pingvin-share 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
