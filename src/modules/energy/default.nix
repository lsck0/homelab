# energy_model.py and its inputs as a python module, for 104-internal-terminal's energy-sync.py and
# 105-internal-grafana's spot-price.py and its grafana board (lib/dashboards/energy.py)
{ pkgs }:
pkgs.python3Packages.toPythonModule (pkgs.runCommand "energy-model" {
  inputs = builtins.toJSON (import ./lib/inputs.nix);
  passAsFile = [ "inputs" ];
} ''
  dir=$out/${pkgs.python3.sitePackages}
  install -Dm644 ${./lib/energy_model.py} $dir/energy_model.py
  install -Dm644 "$inputsPath" $dir/energy_inputs.json
'')
