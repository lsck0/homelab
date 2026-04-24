{ pkgs, lib, nixpkgs, common }:
let
  goldenConfig = (lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      common
      ({ lib, ... }: {
        services.cloud-init.enable = true;
        services.cloud-init.network.enable = true;
        services.cloud-init.settings = {
          users = [ "root" ];
          disable_root = false;
        };
      })
    ];
  }).config;
in import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
  inherit pkgs lib;
  config = goldenConfig;
  format = "qcow2";
  diskSize = "auto";
  additionalSpace = "1G";
  label = "nixos";
}
