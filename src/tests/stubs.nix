# the lab's module stack for tests that boot one module or instance without modules/base: the modules base.nix
# would bring that the instances lean on, sops and the nas as stand-ins (stubs/), and the lab's static facts
#
# A test that runs the production stack instead uses lib/lab.nix, whose nodes import base.nix and stubs/sops.nix.
{ lib, ... }:
let
  # the collected facts (modules/lab), the same the flake hands every host
  facts = import ../modules/lab { inherit lib; };
in {
  imports = [
    ./stubs/sops.nix
    ./stubs/nas.nix
    ./stubs/platform.nix
    ../modules/apps-catalog
    ../modules/network.nix
    ../modules/db-backup
    ../modules/local-state
    ../modules/tokens
    ../modules/textfile.nix
  ];

  _module.args = {
    # network.nix and the catalog read the inventory; a test may pass its own
    inventory = lib.mkDefault facts.inventory;
    # apps-catalog.nix's default catalog
    lab = lib.mkDefault facts;
    # static host facts, the same file the flake hands every host
    site = lib.importJSON ../generated/site.json;
  };
}
