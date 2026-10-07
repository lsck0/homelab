# lab-wide: the lab's laws, over every configuration
# the lab's laws, checked against the real configurations at evaluation time: every tests/policy/<area>.nix is a
# function of the facts below returning a list of violations (strings, empty when the law holds); this check
# fails listing all of them, each prefixed with its file.
#
#   # tests/policy/<area>.nix
#   { lib, configs, inventory, catalog, appsCatalog, ... }:
#   lib.concatLists (lib.mapAttrsToList (name: config:
#     lib.optional (<broken> config) "${name}: <what is wrong and where>") configs)
#
# Facts: configs (configuration name -> its evaluated nixos config, every host of the flake), lab (modules/lab),
# inventory, site, nasClients, appsCatalog (src/apps/ as the hosts read it) and catalog (modules/catalog.nix over it).
# A law states the policy itself, not a copy of the module that implements it.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  configs = lib.mapAttrs (_: system: system.config) inputs.self.nixosConfigurations;
  # every host reads the same catalog; the router is one that always exists
  appsCatalog = configs."300-router".homelab.appsCatalog;
  facts = {
    inherit lib configs appsCatalog;
    inherit (specialArgs) inventory site nasClients lab;
    catalog = import ../modules/catalog.nix { inherit lib appsCatalog; inherit (specialArgs) inventory site lab; };
  };

  lawFiles = lib.filterAttrs (file: kind: kind == "regular" && lib.hasSuffix ".nix" file) (builtins.readDir ./policy);
  violations = lib.concatLists (lib.mapAttrsToList (file: _:
    map (violation: "policy/${file}: ${violation}") (import ./policy/${file} facts)) lawFiles);
  report = pkgs.writeText "policy-violations" (lib.concatLines violations);
  count = attrs: toString (lib.length (lib.attrNames attrs));
in
pkgs.runCommand "policy-eval" { } (if violations == [ ] then ''
  echo "policy-eval: ${count lawFiles} law files hold over ${count configs} configurations"
  touch $out
'' else ''
  echo "policy-eval: ${toString (lib.length violations)} violation(s):" >&2
  cat ${report} >&2
  exit 1
'')
