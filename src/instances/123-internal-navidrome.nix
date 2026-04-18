{ nasMount, nasMedia, ... }: {
  networking.hostName = "vm-123";

  fileSystems = nasMount "/var/lib/navidrome" "navidrome"
    // nasMedia "/srv/music" "music";

  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:latest";
    ports = [ "80:4533" ];
    volumes = [
      "/var/lib/navidrome:/data"
      "/srv/music:/music:ro"
    ];
    environment = {
      ND_SCANSCHEDULE = "1h";
      ND_LOGLEVEL = "info";
      ND_BASEURL = "";
      ND_REVERSEPROXYUSERHEADER = "X-Authentik-Username";
      ND_REVERSEPROXYWHITELIST = "10.100.0.100/32";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/navidrome 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
