# bazarr: subtitles for radarr and sonarr; /data and the token share come from the servarr module
{ pkgs, nasMount, retry, ... }: {
  fileSystems = nasMount "/var/lib/bazarr" "bazarr";

  virtualisation.oci-containers.containers.bazarr = {
    image = "lscr.io/linuxserver/bazarr:v1.6.1-ls364";
    ports = [ "6767:6767" ];
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

  networking.firewall.allowedTCPPorts = [ 6767 ];

  # authelia gates the route, arr-wire drives the api from this host
  homelab.ingressOnly.ports = [ 6767 ];
}
