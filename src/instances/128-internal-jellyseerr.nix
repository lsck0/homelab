{ pkgs, nasMount, retry, ... }: {
  networking.hostName = "vm-128";

  # Seerr (formerly Jellyseerr), request movies, series and anime; approved requests go
  fileSystems = nasMount "/var/lib/jellyseerr" "jellyseerr"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.jellyseerr = {
    # the old fallenbagel/jellyseerr image is frozen at 2.7 and cannot log in to Jellyfin 12
    image = "ghcr.io/seerr-team/seerr:v3.4.1";
    extraOptions = [ "--init" ];
    ports = [ "80:5055" ];
    volumes = [ "/var/lib/jellyseerr:/app/config" ];
    environment = {
      TZ = "Europe/Berlin";
      PORT = "5055";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyseerr 0750 1000 1000 -"
    # the Seerr image runs as node:node (uid 1000); the old fallenbagel image ran as root
    "Z /var/lib/jellyseerr - 1000 1000 -"
  ];

  systemd.services.jellyseerr-token = {
    description = "Export Jellyseerr API key";
    after = [ "podman-jellyseerr.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.jq pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      conf=/var/lib/jellyseerr/settings.json
      ${retry} 90 2 test -f $conf
      key=$(jq -r '.main.apiKey // empty' $conf)
      [ -n "$key" ] || exit 1
      echo -n "$key" > /var/lib/homepage-tokens/jellyseerr-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
