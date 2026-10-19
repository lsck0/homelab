# vm-124's subsonic api answers its direct clients outside the lab and its granted guests, never a whole zone of the lab
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  net = import ../../../../modules/net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  guard = inputs.self.nixosConfigurations."124-internal-navidrome".config.homelab.ingressOnly;
  port = toString specialArgs.lab.catalog.internal.navidrome.port;
  zoneSubnets = map (zone: zone.subnet) (lib.attrValues net.zones);
in
assert lib.assertMsg (lib.elem (lib.toInt port) guard.ports) "124-internal-navidrome leaves its port ${port} unguarded";
assert lib.assertMsg (
  lib.intersectLists zoneSubnets guard.allowed.${port} == [ ]
) "124-internal-navidrome admits a whole lab zone on ${port}: ${toString guard.allowed.${port}}";
pkgs.runCommand "navidrome-guard" { } "touch $out"
