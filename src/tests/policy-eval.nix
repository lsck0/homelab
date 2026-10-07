# lab-wide: the lab's laws, over every configuration
# the lab's laws, checked against the real configurations at evaluation time: every tests/policy/<area>.nix is a
# function of the facts (tests/policy/lib/facts.nix) returning a list of violations (strings, empty when the law
# holds); this check fails listing all of them, each prefixed with its file. tests/policy-controls.nix shows each
# law reporting its own violation.
#
#   # tests/policy/<area>.nix
#   { lib, configs, lab, catalog, ... }:
#   lib.concatLists (lib.mapAttrsToList (name: config:
#     lib.optional (<broken> config) "${name}: <what is wrong and where>") configs)
#
# A law states the policy itself, not a copy of the module that implements it.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  facts = import ./policy/lib/facts.nix { inherit lib inputs specialArgs; };

  lawFiles = lib.filterAttrs (file: kind: kind == "regular" && lib.hasSuffix ".nix" file) (builtins.readDir ./policy);
  violations = lib.concatLists (lib.mapAttrsToList (file: _:
    map (violation: "policy/${file}: ${violation}") (import ./policy/${file} facts)) lawFiles);
  report = pkgs.writeText "policy-violations" (lib.concatLines violations);
  count = attrs: toString (lib.length (lib.attrNames attrs));
in
pkgs.runCommand "policy-eval" { } (if violations == [ ] then ''
  echo "policy-eval: ${count lawFiles} law files hold over ${count facts.configs} configurations"
  touch $out
'' else ''
  echo "policy-eval: ${toString (lib.length violations)} violation(s):" >&2
  cat ${report} >&2
  exit 1
'')
