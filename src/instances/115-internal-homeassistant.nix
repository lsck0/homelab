{ pkgs, nasMount, ... }:
let
  hassConfig = pkgs.writeText "configuration.yaml" ''
    default_config:
    frontend:
      themes: !include_dir_merge_named themes
    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml
    http:
      server_host: 0.0.0.0
      use_x_forwarded_for: true
      trusted_proxies:
        - 10.100.0.0/24
        - 10.0.0.0/8
  '';
in {
  networking.hostName = "vm-115";

  fileSystems = nasMount "/var/lib/homeassistant" "homeassistant"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:stable";
    ports = [ "80:8123" ];
    volumes = [
      "/var/lib/homeassistant:/config"
      "${hassConfig}:/config/configuration.yaml:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant 0750 1000 1000 -"
    "d /var/lib/homeassistant/themes 0750 1000 1000 -"
    "f /var/lib/homeassistant/automations.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scripts.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scenes.yaml 0640 1000 1000 -"
  ];

  # Generate long-lived access token for Homepage widget
  systemd.services.hass-homepage-token = {
    description = "Generate Home Assistant token for Homepage";
    after = [ "podman-homeassistant.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/hass-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # Wait for HA to be ready
      for i in $(seq 1 120); do
        curl -sf http://127.0.0.1:80/api/ >/dev/null 2>&1 && break
        sleep 2
      done
      # Long-lived tokens can only be created via the UI or onboarding API
      # Write a placeholder — user must create token via HA UI:
      # Profile → Security → Long-Lived Access Tokens → Create Token
      echo "NEEDS_MANUAL_SETUP" > "$TOKEN_FILE"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
