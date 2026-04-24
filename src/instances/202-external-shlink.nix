{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-202";
  fileSystems = nasMount "/var/lib/shlink" "shlink"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.shlink = {
    image = "shlinkio/shlink:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/shlink:/etc/shlink/data" ];
    environment = {
      DEFAULT_DOMAIN = "shlink.lsck0.dev";
      IS_HTTPS_ENABLED = "true";
      DB_DRIVER = "sqlite";
      TIMEZONE = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/shlink 0750 1001 1001 -"
  ];

  # Generate API key for Homepage widget
  systemd.services.shlink-homepage-token = {
    description = "Generate Shlink API key for Homepage";
    after = [ "podman-shlink.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/shlink-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0

      # Wait for Shlink to be ready
      for i in $(seq 1 60); do
        podman exec shlink shlink api-key:list 2>/dev/null && break
        sleep 2
      done

      KEY=$(podman exec shlink shlink api-key:generate --no-interaction 2>/dev/null | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
      if [ -n "$KEY" ]; then
        echo -n "$KEY" > "$TOKEN_FILE"
        echo "Shlink Homepage API key created"
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
