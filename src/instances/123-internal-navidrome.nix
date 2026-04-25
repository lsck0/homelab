{ pkgs, nasMount, nasMedia, ... }: {
  networking.hostName = "vm-123";

  fileSystems = nasMount "/var/lib/navidrome" "navidrome"
    // nasMedia "/srv/music" "music"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

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

  # Generate Subsonic API credentials for Homepage widget
  systemd.services.navidrome-homepage-token = {
    description = "Generate Navidrome credentials for Homepage";
    after = [ "podman-navidrome.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/navidrome-user.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && \
        [ -f "/var/lib/homepage-tokens/navidrome-token.token" ] && exit 0

      # Wait for Navidrome to be ready
      for i in $(seq 1 90); do
        curl -sf http://127.0.0.1:80/ping >/dev/null 2>&1 && break
        sleep 2
      done

      # Create initial admin user via Navidrome API (first-run only)
      curl -sf -X POST "http://127.0.0.1:80/api/user" \
        -H "Content-Type: application/json" \
        -d '{"userName":"admin","name":"Admin","password":"admin","isAdmin":true}' 2>/dev/null || true

      # Generate Subsonic API credentials: token = md5(password + salt)
      SALT=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
      TOKEN=$(printf '%s' "admin$SALT" | md5sum | cut -d' ' -f1)

      echo -n "admin" > /var/lib/homepage-tokens/navidrome-user.token
      echo -n "$TOKEN" > /var/lib/homepage-tokens/navidrome-token.token
      echo -n "$SALT" > /var/lib/homepage-tokens/navidrome-salt.token
      echo "Navidrome Homepage credentials created"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
