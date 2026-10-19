# janitorr deletes media: vm-122 renders it a dry run unless homelab.janitorr.deleteMedia says otherwise
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  host = inputs.self.nixosConfigurations."122-internal-jellyfin";
  dryRunOf = system: lib.hasInfix "dry-run: true\n" system.config.environment.etc."janitorr/application.yml.tmpl".text;
  deleting = host.extendModules { modules = [ { homelab.janitorr.deleteMedia = true; } ]; };
in
assert lib.assertMsg (!host.config.homelab.janitorr.deleteMedia) "vm-122 lets janitorr delete media by default";
assert lib.assertMsg (dryRunOf host) "janitorr is no dry run while deleteMedia is off";
assert lib.assertMsg (!dryRunOf deleting) "janitorr stays a dry run with deleteMedia on";
pkgs.runCommand "janitorr" { } "touch $out"
