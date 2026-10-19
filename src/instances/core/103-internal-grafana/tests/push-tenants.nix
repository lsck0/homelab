# the push doors' tenants: every enabled app's nodes may ship its logs, as the promtail of an app node does for every
# app it runs; the trace and profile doors admit an app only when it sends them
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  grafana = inputs.self.nixosConfigurations."103-internal-grafana".config;
  telemetry = import ../../../../modules/telemetry.nix {
    inherit lib;
    inherit (specialArgs) inventory;
  };
  inherit (specialArgs) inventory;
  tenantMap = grafana.services.nginx.appendHttpConfig;
  clusterApps = lib.concatMap (
    c: lib.concatMap (id: lib.mapAttrsToList (app: a: a // { inherit app id; }) c.apps) c.workerIds
  ) (lib.attrValues specialArgs.lab.catalog.clusters);
  logEntryOf = a: "\"${inventory.${toString a.id}.ip} ${telemetry.tenantOf a.app}\" ${telemetry.tenantOf a.app};";
  signalEntryOf = a: "  ${telemetry.tenantOf a.app} ${telemetry.tenantOf a.app};";
  pushVhosts = lib.filterAttrs (
    name: _:
    lib.elem name [
      "loki-push"
      "otlp-http"
      "otlp-grpc"
      "pyroscope-push"
    ]
  ) grafana.services.nginx.virtualHosts;
  gated =
    v:
    lib.all (l: lib.hasInfix "$signal_tenant" (l.extraConfig or "")) (
      lib.attrValues (lib.filterAttrs (path: _: path != "/") v.locations)
    );
  problems =
    map (a: "${a.app} on vm-${toString a.id}: its logs are refused") (
      lib.filter (a: !lib.hasInfix (logEntryOf a) tenantMap) clusterApps
    )
    ++ map (a: "${a.app}: the signal doors ${if telemetry.sendsSignals a then "refuse" else "admit"} it") (
      lib.filter (a: telemetry.sendsSignals a != lib.hasInfix (signalEntryOf a) tenantMap) clusterApps
    )
    ++ lib.optional (gated pushVhosts.loki-push) "the log door turns away an app that sends no traces"
    ++ map (name: "${name} admits an app that sends no signals") (
      lib.attrNames (lib.filterAttrs (name: v: name != "loki-push" && !gated v) pushVhosts)
    );
in
assert lib.assertMsg (clusterApps != [ ]) "the lab enables no app";
assert lib.assertMsg (lib.length (lib.attrNames pushVhosts) == 4) "vm-103 lacks a push door";
assert lib.assertMsg (problems == [ ]) (lib.concatLines problems);
pkgs.runCommand "push-tenants" { } "touch $out"
