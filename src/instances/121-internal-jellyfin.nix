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
    path = [ pkgs.curl pkgs.jq ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/jellyfin-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      for i in $(seq 1 90); do
        curl -sf http://127.0.0.1:80/health >/dev/null 2>&1 && break
        sleep 2
      done
      # Create API key via Jellyfin API (no auth needed on first setup / local)
      curl -sf -X POST "http://127.0.0.1:80/Auth/Keys" \
        -H "Content-Type: application/json" \
        -d '{"App":"homepage"}' 2>/dev/null || true
      # Fetch the key
      KEY=$(curl -sf "http://127.0.0.1:80/Auth/Keys" 2>/dev/null \
        | jq -r '.Items[] | select(.AppName=="homepage") | .AccessToken' 2>/dev/null | head -1)
      [ -n "$KEY" ] && echo -n "$KEY" > "$TOKEN_FILE"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
