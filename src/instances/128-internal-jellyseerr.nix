{ pkgs, nasMount, retry, ... }: {
  networking.hostName = "vm-128";

  # seerr: media requests, approvals go to the arr
  fileSystems = nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # sqlite on local disk: over nfs it died of SIGBUS every few minutes; the nas keeps a nightly copy
  homelab.localState.jellyseerr = {
    path = "/var/lib/jellyseerr";
    share = "jellyseerr";
    unit = "podman-jellyseerr";
    sqlite = [ "db/db.sqlite3" ];
    exclude = [ "cache" "logs" ];
  };

  virtualisation.oci-containers.containers.jellyseerr = {
    # old jellyseerr image cannot log in to jellyfin 12
    image = "ghcr.io/seerr-team/seerr:v3.4.1";
    # ~250 MiB: vm 30d peak 495 minus the idle base
    extraOptions = [ "--init" "--memory=384m" ];
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
    # an lxc mounts nfs at boot, not on access: never write under an empty mountpoint
    unitConfig.RequiresMountsFor = [ "/var/lib/homepage-tokens" ];
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
