{
  description = "Homelab NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    # Hermes agent (vm-114). Not following our nixpkgs: it is built and tested
    # against nixos-unstable.
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { nixpkgs, sops-nix, ... }@inputs:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    # VM inventory (id -> name/type/ip/enabled/cooldown), exported from
    # instances.tf by sync.sh. Modules take it as the `inventory` argument.
    inventory = builtins.fromJSON (builtins.readFile ./inventory.json);
    specialArgs = { inherit inputs inventory; };

    common = {
      imports = [
        ./modules/base.nix
        sops-nix.nixosModules.sops
      ];
    };

    # one configuration per src/instances/<id>-<type>-<service>.nix (plus the router).
    hostFiles = lib.filterAttrs (name: kind:
      kind == "regular" && builtins.match "([12][0-9]{2}-(internal|external)-.*|300-router)\\.nix" name != null
    ) (builtins.readDir ./instances);
  in {
    # NixOS VM tests: nix build .#checks.x86_64-linux.<name>
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
