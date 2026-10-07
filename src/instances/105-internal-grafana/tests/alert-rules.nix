# the provisioned alert rules of 105-internal-grafana.nix, evaluated by promtool against synthetic series
# (tests/alert_rules_test.py holds the cases): every PromQL rule parses, and the policy's cases fire or stay quiet
{ pkgs, lib, inputs, specialArgs, ... }:
let
  # the real vm-105, with the template app enabled so its board and its rules are built too
  fixtureApp = "wat";
  grafana = (inputs.self.nixosConfigurations."105-internal-grafana".extendModules {
    modules = [{ homelab.appsCatalog = lib.recursiveUpdate specialArgs.lab.appsCatalog { apps.${fixtureApp}.enable = true; }; }];
  }).config;
  rules = pkgs.writeText "grafana-rules.json"
    (builtins.toJSON grafana.services.grafana.provision.alerting.rules.settings.groups);
in
pkgs.runCommand "alert-rules" { nativeBuildInputs = [ pkgs.python3 pkgs.prometheus.cli ]; } ''
  mkdir -p $out
  python3 ${./alert_rules_test.py} ${rules} ${fixtureApp} $out
  cd $out
  promtool check rules rules.json
  promtool test rules tests.json
''
