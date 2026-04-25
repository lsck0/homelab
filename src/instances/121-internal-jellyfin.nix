{ pkgs, nasMount, nasMedia, ... }: {
  networking.hostName = "vm-121";

  fileSystems = nasMount "/var/lib/jellyfin" "jellyfin"
    // nasMedia "/mnt/media" ""
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.jellyfin = {
    image = "jellyfin/jellyfin:latest";
    ports = [ "80:8096" ];
    volumes = [
      "/var/lib/jellyfin/config:/config"
      "/var/lib/jellyfin/cache:/cache"
      "/mnt/media:/media:ro"
    ];
    environment = {
      JELLYFIN_PublishedServerUrl = "https://jellyfin.lsck0.dev";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyfin/config 0750 1000 1000 -"
    "d /var/lib/jellyfin/cache 0750 1000 1000 -"
  ];

  systemd.services.jellyfin-homepage-token = {
    description = "Export Jellyfin API key for Homepage";
    after = [ "podman-jellyfin.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.gnugrep pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/jellyfin-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      for i in $(seq 1 90); do
        curl -sf http://127.0.0.1:80/health >/dev/null 2>&1 && break
        sleep 2
      done

      # Complete startup wizard if needed
      WIZARD=$(curl -sf http://127.0.0.1:80/System/Info/Public 2>/dev/null || true)
      if echo "$WIZARD" | grep -q '"StartupWizardCompleted":false'; then
        curl -sf -X POST "http://127.0.0.1:80/Startup/Configuration" \
          -H "Content-Type: application/json" \
          -d '{"UICulture":"en-US","MetadataCountryCode":"DE","PreferredMetadataLanguage":"en"}' 2>/dev/null || true
        curl -sf -X POST "http://127.0.0.1:80/Startup/User" \
          -H "Content-Type: application/json" \
          -d '{"Name":"admin","Password":"admin"}' 2>/dev/null || true
        curl -sf -X POST "http://127.0.0.1:80/Startup/Complete" 2>/dev/null || true
      fi

      # Authenticate
      AUTH_HDR="X-Emby-Authorization: MediaBrowser Client=\"Homepage\", Device=\"Server\", DeviceId=\"homepage\", Version=\"1.0\""
      ACCESS_TOKEN=$(curl -sf -X POST "http://127.0.0.1:80/Users/AuthenticateByName" \
        -H "Content-Type: application/json" -H "$AUTH_HDR" \
        -d '{"Username":"admin","Pw":"admin"}' 2>/dev/null \
        | grep -oP '"AccessToken"\s*:\s*"\K[^"]+' || true)
      [ -z "$ACCESS_TOKEN" ] && exit 1

      # Create API key
      curl -sf -X POST "http://127.0.0.1:80/Auth/Keys?app=homepage" \
        -H "X-Emby-Token: $ACCESS_TOKEN" 2>/dev/null || true

      # Fetch the key
      KEY=$(curl -sf "http://127.0.0.1:80/Auth/Keys" \
        -H "X-Emby-Token: $ACCESS_TOKEN" 2>/dev/null \
        | grep -oP '"AccessToken"\s*:\s*"\K[^"]+' | head -1 || true)
      [ -n "$KEY" ] && echo -n "$KEY" > "$TOKEN_FILE"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
