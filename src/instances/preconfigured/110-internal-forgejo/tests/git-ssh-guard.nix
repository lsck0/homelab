# vm-110's git over ssh answers its direct clients outside the lab and its granted guests, never a whole zone of the lab
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
  guard = inputs.self.nixosConfigurations."110-internal-forgejo".config.homelab.ingressOnly;
  port = toString (import ../lib/git-ssh.nix).port;
  zoneSubnets = map (zone: zone.subnet) (lib.attrValues net.zones);
in
assert lib.assertMsg (lib.elem (lib.toInt port) guard.ports) "110-internal-forgejo leaves its port ${port} unguarded";
assert lib.assertMsg (
  lib.intersectLists zoneSubnets guard.allowed.${port} == [ ]
) "110-internal-forgejo admits a whole lab zone on ${port}: ${toString guard.allowed.${port}}";
pkgs.runCommand "git-ssh-guard" { } "touch $out"
