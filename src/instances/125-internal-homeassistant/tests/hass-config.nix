# the energy inputs' Home Assistant config (helpers, guarded meter sensors) through home assistant's own validation
# (hass_config_test.py). nixpkgs' home assistant, not the container's: a schema both accept, close in version
{ pkgs, lib, ... }:
let
  energy = import ../lib/home-assistant.nix { inherit lib; };
  inputs = import ../../../modules/energy/lib/inputs.nix;
  ha = pkgs.home-assistant;
  # the package as a module beside its dependencies, so a script can import homeassistant
  python = ha.python.withPackages (_: ha.dependencies ++ [ (ha.python.pkgs.toPythonModule ha) ]);
  configuration = pkgs.writeText "configuration.yaml" ''
    homeassistant:
      time_zone: ${inputs.timeZone}
    input_number: ${energy.inputNumbers}
    input_button: ${energy.inputButtons}
    template: ${energy.templates}
  '';
in
pkgs.runCommand "hass-config" { nativeBuildInputs = [ python ]; } ''
  export HOME=$TMPDIR
  mkdir -p config/custom_templates
  cp ${configuration} config/configuration.yaml
  cp ${energy.meterGuard} config/custom_templates/${energy.meterGuardName}
  python3 ${./hass_config_test.py} config ${toString (lib.length (lib.attrNames inputs.meters))}
  touch $out
''
