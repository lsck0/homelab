{ pkgs, nasMount, nasPath, ... }: {
  networking.hostName = "vm-122";

  fileSystems = nasMount "/var/lib/audiobookshelf" "audiobookshelf"
    // nasPath "/srv/audiobooks" "media/audiobooks"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.audiobookshelf = {
    image = "ghcr.io/advplyr/audiobookshelf:latest";
    ports = [ "80:80" ];
    volumes = [
      "/srv/audiobooks:/audiobooks"
      "/var/lib/audiobookshelf/config:/config"
      "/var/lib/audiobookshelf/metadata:/metadata"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/audiobookshelf/config 0750 1000 1000 -"
    "d /var/lib/audiobookshelf/metadata 0750 1000 1000 -"
  ];

  # Generate API token for Homepage widget
  systemd.services.audiobookshelf-homepage-token = {
    description = "Export Audiobookshelf API token for Homepage";
    after = [ "podman-audiobookshelf.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/audiobookshelf-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # Wait for ABS to be ready
      for i in $(seq 1 90); do
        curl -sf http://127.0.0.1:80/healthcheck >/dev/null 2>&1 && break
        sleep 2
      done
      # Initialize if not yet set up
      STATUS=$(curl -sf http://127.0.0.1:80/status 2>/dev/null || true)
      if echo "$STATUS" | grep -q '"isInit":false'; then
        curl -sf -X POST "http://127.0.0.1:80/init" \
          -H "Content-Type: application/json" \
          -d '{"newRoot":{"username":"admin","password":"admin"}}' 2>/dev/null || true
      fi
      # Login and extract token
      TOKEN=$(curl -sf -X POST "http://127.0.0.1:80/login" \
        -H "Content-Type: application/json" \
        -d '{"username":"admin","password":"admin"}' 2>/dev/null \
        | grep -oP '"token"\s*:\s*"\K[^"]+' || true)
      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Audiobookshelf Homepage token created"
      fi
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
