{ pkgs, nasMount, nasMedia, ... }: {
  networking.hostName = "vm-124";

  fileSystems = nasMount "/var/lib/kavita" "kavita"
    // nasMedia "/srv/manga" "manga"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.kavita = {
    image = "jvmilazz0/kavita:latest";
    ports = [ "80:5000" ];
    volumes = [
      "/var/lib/kavita:/kavita/config"
      "/srv/manga:/manga:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kavita 0750 1000 1000 -"
  ];

  # Export Kavita credentials for Homepage widget
  systemd.services.kavita-homepage-token = {
    description = "Export Kavita credentials for Homepage";
    after = [ "podman-kavita.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/kavita-user.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # Wait for Kavita to be ready
      for i in $(seq 1 90); do
        curl -sf http://127.0.0.1:80/api/health >/dev/null 2>&1 && break
        sleep 2
      done
      # Kavita credentials must be set via UI first
      # Then write them:
      # echo -n "username" > /var/lib/homepage-tokens/kavita-user.token
      # echo -n "password" > /var/lib/homepage-tokens/kavita-pass.token
      echo "NEEDS_MANUAL_SETUP" > "$TOKEN_FILE"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
