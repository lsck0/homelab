# vm-140's tailscale control port answers its direct clients outside the lab and its granted guests, never a whole zone of the lab
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
  guard = inputs.self.nixosConfigurations."140-internal-headscale".config.homelab.ingressOnly;
  port = toString specialArgs.lab.catalog.internal.headscale.port;
  zoneSubnets = map (zone: zone.subnet) (lib.attrValues net.zones);
in
assert lib.assertMsg (lib.elem (lib.toInt port) guard.ports) "140-internal-headscale leaves its port ${port} unguarded";
assert lib.assertMsg (
  lib.intersectLists zoneSubnets guard.allowed.${port} == [ ]
) "140-internal-headscale admits a whole lab zone on ${port}: ${toString guard.allowed.${port}}";
pkgs.runCommand "headscale-guard" { } "touch $out"
