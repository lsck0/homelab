# the provisioned alert rules of vm-103, evaluated by promtool against synthetic series
# (tests/alert_rules_test.py holds the cases): every PromQL rule parses, and the policy's cases fire or stay quiet.
# Every annotation expands with and without a value (tests/annotations_render.go): grafana sends one it cannot raw.
# What the rules rely on is checked at evaluation: every powered guest is scraped and an idle one labeled so, a
# powered-off one is not, and no probe reaches a guest that is not always on (it would wake it, or alarm while it sleeps).
{ pkgs, lib, inputs, specialArgs, ... }:
let
  # the real vm-103, with the template app enabled so its board and its rules are built too
  fixtureApp = "wat";
  hostWith = import ../../../tests/lib/host-with.nix { inherit inputs; };
  grafana = hostWith (specialArgs.lab.withApps (apps: lib.recursiveUpdate apps { ${fixtureApp}.enable = true; })) "103-internal-grafana";
  telemetry = import ../../../modules/telemetry.nix { inherit lib; inherit (specialArgs) inventory; };
  builder = telemetry.vmName specialArgs.inventory.${toString specialArgs.lab.appsCatalog.builder};
  inherit (specialArgs) inventory;
  scrapeOf = name: lib.findFirst (j: j.job_name == name) (throw "no scrape job ${name}") grafana.services.prometheus.scrapeConfigs;
  nodeLabels = lib.listToAttrs (map (c: lib.nameValuePair (lib.head c.targets) c.labels) (scrapeOf "homelab-node-exporter").static_configs);
  probedVms = lib.unique (lib.concatMap (job: map (c: c.labels.vm) (scrapeOf job).static_configs) [ "blackbox-http" "blackbox-tcp" ]);
  guests = lib.filterAttrs (_: v: v.type != "router") inventory;
  problems = lib.concatLists (lib.mapAttrsToList (id: v: let labels = nodeLabels."${v.ip}:9100" or null; in
    if !v.powered then lib.optional (labels != null) "vm-${id} is powered off but scraped"
    else lib.optional (labels == null || (labels.idle or null) != (if v.idle == null then null else "true"))
      "vm-${id} is scraped without its idle label (idle: ${toString v.idle})"
    ++ lib.optional (v.idle != null && lib.elem (telemetry.vmName v) probedVms) "vm-${id} sleeps on purpose but is probed"
  ) guests);
  rules = assert lib.assertMsg (problems == [ ]) (lib.concatLines problems); pkgs.writeText "grafana-rules.json"
    (builtins.toJSON grafana.services.grafana.provision.alerting.rules.settings.groups);
in
pkgs.runCommand "alert-rules" { nativeBuildInputs = [ pkgs.python3 pkgs.prometheus.cli pkgs.go ]; } ''
  mkdir -p $out
  HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache go run ${./annotations_render.go} ${rules}
  python3 ${./alert_rules_test.py} ${rules} ${fixtureApp} ${builder} $out
  cd $out
  promtool check rules rules.json
  promtool test rules tests.json
''
