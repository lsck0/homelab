{ pkgs, nasMount, retry, ... }: {
  networking.hostName = "vm-128";

  # seerr: media requests, approvals go to the arr
  fileSystems = nasMount "/var/lib/jellyseerr" "jellyseerr"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.jellyseerr = {
    # old jellyseerr image cannot log in to jellyfin 12
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
    # seerr runs as uid 1000, the old image as root
    "Z /var/lib/jellyseerr - 1000 1000 -"
  ];

  systemd.services.jellyseerr-token = {
    description = "Export Jellyseerr API key";
    after = [ "podman-jellyseerr.service" ];
    # an lxc mounts nfs at boot, not on access: never write under an empty mountpoint
    unitConfig.RequiresMountsFor = [ "/var/lib/jellyseerr" "/var/lib/homepage-tokens" ];
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
