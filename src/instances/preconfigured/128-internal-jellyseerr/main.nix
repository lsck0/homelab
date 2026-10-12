# seerr: media requests, approvals go to the arrs (arr-wire on vm-130 sets it up)
{ catalog, pkgs, retry, setupUnit, site, ... }:
let
  route = catalog.internal.jellyseerr;
  containerPort = 5055;
  # the container's user, which owns the state dir
  containerUid = 1000;
  stateDir = "/var/lib/jellyseerr";
  conf = "${stateDir}/settings.json";
in {
  # sqlite on local disk: over nfs it died of SIGBUS every few minutes; the nas keeps a nightly copy
  homelab.localState.jellyseerr = {
    path = stateDir;
    unit = "podman-jellyseerr";
    sqlite = [ "db/db.sqlite3" ];
    exclude = [ "cache" "logs" ];
  };

  virtualisation.oci-containers.containers.jellyseerr = {
    # old jellyseerr image cannot log in to jellyfin 12
    image = "ghcr.io/seerr-team/seerr:v3.4.1";
    # ~250 MiB: vm 30d peak 495 minus the idle base
    extraOptions = [ "--init" "--memory=384m" ];
    ports = [ "${toString route.port}:${toString containerPort}" ];
    volumes = [ "${stateDir}:/app/config" ];
    environment = {
      TZ = site.timeZone;
      PORT = toString containerPort;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${toString containerUid} ${toString containerUid} -"
  ];

  # the api key seerr generates on its first start
  systemd.services.jellyseerr-token = setupUnit {
    description = "Export Jellyseerr API key";
    after = [ "podman-jellyseerr.service" ];
    path = [ pkgs.jq pkgs.coreutils ];
    script = ''
      ${retry} 90 2 test -f ${conf}
      jq -j '.main.apiKey // empty' ${conf} | token_write jellyseerr-key
    '';
  };
}
