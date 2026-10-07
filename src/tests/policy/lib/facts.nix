# what every law reads (tests/policy-eval.nix, tests/policy-controls.nix): the real configurations and the lab
#
#   configs      configuration name -> its evaluated nixos config, every host of the flake
#   lab          modules/lab, and from it inventory, site, nasClients, appsCatalog (typed) and catalog
#   src          the tree the file laws read (placement, secrets); a control hands them a fixture tree
{ lib, inputs, specialArgs }:
{
  inherit lib;
  configs = lib.mapAttrs (_: system: system.config) inputs.self.nixosConfigurations;
  inherit (specialArgs) lab inventory site nasClients;
  inherit (specialArgs.lab) appsCatalog catalog;
  src = ../../..;
}
