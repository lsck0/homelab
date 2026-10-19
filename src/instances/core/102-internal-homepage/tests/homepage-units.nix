# a homepage container stopped by a failed switch comes back: homepage-config wants every podman-<route>, so its
# restart starts them, and the env refresh timer starts any that stayed down
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  homepage = inputs.self.nixosConfigurations."102-internal-homepage".config;
  inherit (homepage.systemd) services;
  routes = lib.attrNames homepage.virtualisation.oci-containers.containers;
  podmanUnitOf = route: "podman-${route}.service";
  unwanted = lib.filter (route: !lib.elem "homepage-config.service" services."podman-${route}".wantedBy) routes;
  refreshStart = "systemctl start ${toString (map podmanUnitOf routes)}";
in
assert lib.assertMsg (routes != [ ]) "vm-102 runs no homepage container";
assert lib.assertMsg (unwanted == [ ]) "homepage-config does not want the containers of ${toString unwanted}";
assert lib.assertMsg (lib.hasInfix refreshStart services.homepage-env-refresh.script)
  "homepage-env-refresh does not start the stopped containers (${refreshStart})";
pkgs.runCommand "homepage-units" { } "touch $out"
