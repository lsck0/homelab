{ catalog, nasMount, site, ... }:
let
  route = catalog.external.share;
  data = "/var/lib/pingvin-share";
  # the image's node user
  appUid = "1000";
in {
  homelab.nasMounts = nasMount data "share";

  # the maintained fork of the archived Pingvin Share; it migrates the db forward at start, the nas copy is the rollback
  virtualisation.oci-containers.containers.share = {
    image = "ghcr.io/smp46/pingvin-share-x:v2.0.0";
    ports = [ "${toString route.port}:3000" ];
    volumes = [ "${data}:/opt/app/backend/data" ];
    # ~220 MiB: vm 30d peak 469 minus the idle base
    extraOptions = [ "--memory=384m" ];
    environment = {
      # only the zone's ingress reaches the port (the guard, modules/network.nix), its x-forwarded-for is the visitor's
      TRUST_PROXY = "true";
      APP_URL = "https://${route.host}.${site.domain}";
    };
  };

  systemd.tmpfiles.rules = [ "d ${data} 0750 ${appUid} ${appUid} -" ];
}
