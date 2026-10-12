{ catalog, nasMount, ... }:
let
  route = catalog.external.privatebin;
  data = "/var/lib/privatebin";
  # the image's nginx-fpm user
  phpUid = "82";
in {
  homelab.nasMounts = nasMount data "privatebin";

  virtualisation.oci-containers.containers.privatebin = {
    image = "privatebin/nginx-fpm-alpine:2.0.4";
    ports = [ "${toString route.port}:8080" ];
    volumes = [ "${data}:/srv/data" ];
    # ~70 MiB: vm 30d peak 323 minus the idle base; php-fpm workers take up to 128M each
    extraOptions = [ "--memory=256m" ];
  };

  systemd.tmpfiles.rules = [ "d ${data} 0750 ${phpUid} ${phpUid} -" ];
}
