{ catalog, nasMount, ... }:
let
  route = catalog.external.privatebin;
  data = "/var/lib/privatebin";
  # the image's nginx-fpm user
  phpUid = "82";
in
{
  homelab.nasMounts = nasMount data "privatebin";

  virtualisation.oci-containers.containers.privatebin = {
    image = "privatebin/nginx-fpm-alpine:2.0.4@sha256:96171f34dd07f6c655cb3a311de24c1e9bafd05307ea9b6d38443863f6b48153";
    ports = [ "${toString route.port}:8080" ];
    volumes = [ "${data}:/srv/data" ];
    # ~70 MiB: vm 30d peak 323 minus the idle base; php-fpm workers take up to 128M each
    extraOptions = [ "--memory=256m" ];
  };

  systemd.tmpfiles.rules = [ "d ${data} 0750 ${phpUid} ${phpUid} -" ];
}
