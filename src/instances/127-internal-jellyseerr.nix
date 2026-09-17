{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-127";

  # Seerr (formerly Jellyseerr), request movies, series and anime; approved requests go to
  # Radarr/Sonarr (anime -> Sonarr anime folder). Connected to Jellyfin and the
  # *arrs by vm-132. Behind Authelia at requests.lsck0.dev.
  fileSystems = nasMount "/var/lib/jellyseerr" "jellyseerr"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.jellyseerr = {
    # the old fallenbagel/jellyseerr image is frozen at 2.7 and cannot log in
    # to Jellyfin 12; the project continues as Seerr.
    image = "ghcr.io/seerr-team/seerr:latest";
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
  ];

  systemd.services.jellyseerr-token = {
    description = "Export Jellyseerr API key";
    after = [ "podman-jellyseerr.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.jq pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      conf=/var/lib/jellyseerr/settings.json
      for i in $(seq 1 90); do [ -f $conf ] && break; sleep 2; done
      key=$(jq -r '.main.apiKey // empty' $conf)
      [ -n "$key" ] || exit 1
      echo -n "$key" > /var/lib/homepage-tokens/jellyseerr-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
