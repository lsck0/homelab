# vm-112's publish container runs on the host's network: the dmz mirror admits the archrepo push from vm-112 alone,
# never from podman's bridge
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  inherit (inputs.self.nixosConfigurations."112-internal-archbuild".config.systemd.services.archbuild) script;
  publishRun =
    lib.findFirst (lib.hasInfix "--name archbuild-publish") (throw "the archbuild unit runs no publish container")
      (lib.splitString "\n" script);
in
assert lib.assertMsg (lib.hasInfix "--network host" publishRun)
  "the archbuild publish container runs on podman's bridge, not the host's network: ${publishRun}";
pkgs.runCommand "archbuild-units" { } "touch $out"
