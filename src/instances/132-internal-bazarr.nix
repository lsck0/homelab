{ pkgs, nasMount, nasPath, retry, ... }: {
  networking.hostName = "vm-132";

  # Bazarr: subtitles for the Radarr/Sonarr libraries. Same /data/media path
  # as the *arrs (so their file paths resolve) and writable (subtitles are
  # written next to the media). Sonarr/Radarr connections are set by vm-133.
  # behind Authelia at subs.lsck0.dev.
  fileSystems = nasMount "/var/lib/bazarr" "bazarr"
    // nasPath "/data/media" "bulk/media"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.bazarr = {
    image = "lscr.io/linuxserver/bazarr:v1.6.1-ls364";
    ports = [ "80:6767" ];
    volumes = [
      "/var/lib/bazarr:/config"
      "/data/media:/data/media"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "Europe/Berlin";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/bazarr 0750 1000 1000 -"
  ];

  systemd.services.bazarr-token = {
    description = "Export Bazarr API key";
    after = [ "podman-bazarr.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.yq-go pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
    script = ''
      conf=/var/lib/bazarr/config/config.yaml
      ${retry} 90 2 test -f $conf
      key=$(yq '.auth.apikey' $conf)
      [ -n "$key" ] && [ "$key" != null ] || exit 1
      echo -n "$key" > /var/lib/homepage-tokens/bazarr-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];

  # Bazarr's own login is off (Authelia gates the route); vm-133 drives its API.
  homelab.ingressOnly = {
    ports = [ 80 ];
    extraSources = [ "10.100.0.133/32" ];
  };
}
