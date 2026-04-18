{ pkgs, ... }:
let
  hassConfig = pkgs.writeText "configuration.yaml" ''
    default_config:
    frontend:
      themes: !include_dir_merge_named themes
    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml
    http:
      use_x_forwarded_for: true
      trusted_proxies:
        - 10.100.0.100
  '';
in {
  networking.hostName = "vm-121";

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

  networking.firewall.allowedTCPPorts = [ 80 ];
}
