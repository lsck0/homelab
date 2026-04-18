{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-114";

  fileSystems = nasMount "/var/lib/prowlarr" "prowlarr";

  virtualisation.oci-containers.containers.prowlarr = {
    image = "lscr.io/linuxserver/prowlarr:latest";
    ports = [ "80:9696" ];
    volumes = [
      "/var/lib/prowlarr:/config"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/prowlarr 0750 1000 1000 -"
  ];

  # Disable built-in auth — authentik ForwardAuth handles access control
  systemd.services.prowlarr-disable-auth = {
    description = "Disable Prowlarr built-in auth";
    after = [ "podman-prowlarr.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      conf="/var/lib/prowlarr/config.xml"
      for i in $(seq 1 60); do
        [ -f "$conf" ] && break
        sleep 2
      done
      [ ! -f "$conf" ] && exit 1

      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' "$conf"
      ${pkgs.gnused}/bin/sed -i 's|<AuthenticationRequired>.*</AuthenticationRequired>|<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>|' "$conf"

      ${pkgs.podman}/bin/podman restart prowlarr
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
