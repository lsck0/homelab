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
    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/kavita-user.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && \
        [ "$(cat "$TOKEN_FILE")" != "NEEDS_MANUAL_SETUP" ] && exit 0

      # Wait for Kavita to be ready
      for i in $(seq 1 90); do
        CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:80/ 2>/dev/null || true)
        [ -n "$CODE" ] && [ "$CODE" != "000" ] && break
        sleep 2
      done

      # Register admin user if first run (Kavita returns 200 on /api/account/register for first user)
      curl -sf -X POST "http://127.0.0.1:80/api/Account/register" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"Admin123!","email":"admin@internal"}' 2>/dev/null || true

      # Login to get API token
      LOGIN=$(curl -sf -X POST "http://127.0.0.1:80/api/Account/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"Admin123!"}' 2>/dev/null || true)
      API_KEY=$(echo "$LOGIN" | grep -oP '"apiKey"\s*:\s*"\K[^"]+' || true)

      if [ -n "$API_KEY" ]; then
        echo -n "admin" > /var/lib/homepage-tokens/kavita-user.token
        echo -n "Admin123!" > /var/lib/homepage-tokens/kavita-pass.token
        echo "Kavita Homepage credentials created"
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
