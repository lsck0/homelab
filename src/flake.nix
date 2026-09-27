{
  description = "Homelab NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # github deprecates runners faster than stable updates
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    # hermes agent (vm-114)
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # owner's personal skills, passed to hermes as-is
    dotfiles.url = "github:lsck0/arch-dotfiles";
    dotfiles.flake = false;
  };

  outputs = { nixpkgs, sops-nix, ... }@inputs:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    # vm inventory, exported from instances.tf by sync.sh
    inventory = builtins.fromJSON (builtins.readFile ./inventory.json);
    specialArgs = { inherit inputs inventory; };

    common = {
      imports = [
        ./modules/base.nix
        ./modules/egress-vpn.nix
        sops-nix.nixosModules.sops
      ];
    };

    # one config per src/instances/*.nix plus the router
    hostFiles = lib.filterAttrs (name: kind:
      kind == "regular" && builtins.match "([12][0-9]{2}-(internal|external)-.*|300-router)\\.nix" name != null
    ) (builtins.readDir ./instances);
  in {
    # usage: nix build .#checks.x86_64-linux.<name>
    checks.${system} = lib.genAttrs [ "on-demand" "kopia" "swarm" "minecraft" "monitoring" "renumber" ]
      (name: import ./tests/${name}.nix { inherit pkgs lib inputs; });

    packages.${system}.cloud-image = import ./modules/cloud-image.nix {
      inherit pkgs lib nixpkgs common specialArgs;
    };

    nixosConfigurations = lib.mapAttrs' (file: _:
      lib.nameValuePair (lib.removeSuffix ".nix" file) (lib.nixosSystem {
        inherit system specialArgs;
        modules = [ common ./instances/${file} ];
      })
    ) hostFiles;
  };
}
