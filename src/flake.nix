{
  description = "Homelab NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, sops-nix, ... }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    common = {
      imports = [
        ./modules/base.nix
        sops-nix.nixosModules.sops
      ];
    };

    hostDirs = [ ./instances ];

    hostEntries = builtins.concatLists (map (dir:
      map (name: {
        inherit dir name;
      }) (builtins.filter
        (name:
          (name == "300-router.nix") ||
          ((builtins.match "^[12][0-9]{2}-(internal|external)-.*\\.nix$" name) != null)
        )
        (builtins.attrNames (builtins.readDir dir)))
    ) hostDirs);

    parseEntry = entry: let
      basename = lib.removeSuffix ".nix" entry.name;
    in basename;

    hostConfigs = builtins.listToAttrs (map (entry: {
      name = parseEntry entry;
      value = lib.nixosSystem {
        inherit system;
        modules = [
          common
          (entry.dir + "/${entry.name}")
        ];
      };
    }) hostEntries);

  in {
    packages.${system}.cloud-image = import ./modules/cloud-image.nix {
      inherit pkgs lib nixpkgs common;
    };

    nixosConfigurations = hostConfigs;
  };
}
