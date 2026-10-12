{ catalog, nasMount, pkgs, site, ... }:
let
  route = catalog.external.share;
  data = "/var/lib/pingvin-share";
  # the image's node user
  appUid = "1000";
  # a public share is a dead drop, not a file host: every link dies within this
  expirationMax = "30 days";
  # declared settings win over the database at every start and lock the admin ui (backend/src/config/config.service.ts)
  config = (pkgs.formats.yaml { }).generate "pingvin-share.yaml" {
    general.appUrl = "https://${route.host}.${site.domain}";
    security = { allowRegistration = false; allowUnauthenticatedShares = false; secureCookies = true; };
    share.maxExpiration = expirationMax;
  };
in {
  homelab.nasMounts = nasMount data "share";

  # the maintained fork of the archived Pingvin Share; it migrates the db forward at start, the nas copy is the rollback
  virtualisation.oci-containers.containers.share = {
    image = "ghcr.io/smp46/pingvin-share-x:v2.0.0";
    ports = [ "${toString route.port}:3000" ];
    volumes = [ "${data}:/opt/app/backend/data" "${config}:/opt/app/config.yaml:ro" ];
    # ~220 MiB: vm 30d peak 469 minus the idle base
    extraOptions = [ "--memory=384m" ];
    # only the zone's ingress reaches the port (the guard, modules/network.nix), its x-forwarded-for is the visitor's
    environment.TRUST_PROXY = "true";
  };

  systemd.tmpfiles.rules = [ "d ${data} 0750 ${appUid} ${appUid} -" ];
}
