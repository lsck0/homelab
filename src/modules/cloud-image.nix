{
  pkgs,
  lib,
  nixpkgs,
  common,
  specialArgs,
}:
let
  goldenConfig =
    (lib.nixosSystem {
      inherit specialArgs;
      system = "x86_64-linux";
      modules = [
        common
        (_: {
          services.cloud-init.enable = true;
          services.cloud-init.network.enable = true;
          services.cloud-init.settings = {
            users = [ "root" ];
            disable_root = false;
            # sshd-keygen makes the keys the guests keep; cloud-init writing them too races it into a failed unit
            ssh_deletekeys = false;
            ssh_genkeytypes = [ ];
          };
          # networkd would bring it, and the first switch removes it: dbus restarts it orphaned and it stays failed
          services.resolved.enable = false;
        })
      ];
    }).config;
in
# the law (tests/policy/golden-image.nix) reads the image's configuration
lib.extendDerivation true { config = goldenConfig; } (
  import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
    inherit pkgs lib;
    config = goldenConfig;
    format = "qcow2";
    diskSize = "auto";
    additionalSpace = "1G";
    label = "nixos";
  }
)
