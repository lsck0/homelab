# grafana's provisioning keeps no secureJsonData inline in the store: every datasource header comes from a file holding
# the tenant it read before, the module warns of no leak, and the contact points' store template holds only placeholders
{
  pkgs,
  lib,
  inputs,
  specialArgs,
  ...
}:
let
  # traced and profiled, so the tempo and pyroscope datasources of an app are built too
  fixtureApp = "wat";
  lab = specialArgs.lab.withApps (apps: lib.recursiveUpdate apps { ${fixtureApp}.enable = true; });
  hostWith = import ../../../../tests/lib/host-with.nix { inherit inputs; };
  grafana = hostWith lab "103-internal-grafana";
  telemetry = import ../../../../modules/telemetry.nix {
    inherit lib;
    inherit (specialArgs) inventory;
  };
  contactPointSecrets = [
    "ntfy-grafana-password"
    "telegram-bot-token"
    "telegram-chat-id"
  ];

  tenantExpectedOf =
    uid:
    let
      appUid = builtins.match "(loki|tempo|pyroscope)-(.+)" uid;
    in
    if uid == "loki" then
      lib.concatStringsSep "|" ([ telemetry.labTenant ] ++ map telemetry.tenantOf (lib.attrNames lab.catalog.apps))
    else if uid == "tempo" then
      telemetry.labTenant
    else if appUid != null then
      telemetry.tenantOf (lib.elemAt appUid 1)
    else
      throw "datasource ${uid} carries a tenant header nobody expects";

  inherit (grafana.services.grafana.provision.datasources.settings) datasources;
  headers = lib.concatMap (
    d:
    lib.mapAttrsToList (key: value: {
      inherit (d) uid;
      inherit key value;
      # match drops the string context the build needs to see the file
      path =
        if builtins.match "\\$__file\\{/.+}" value == null then
          null
        else
          lib.removeSuffix "}" (lib.removePrefix "$__file{" value);
    }) (lib.filterAttrs (_: v: v != null) (if d.secureJsonData == null then { } else d.secureJsonData))
  ) datasources;
  inline = lib.filter (h: h.path == null) headers;
  uids = map (h: h.uid) headers;
  template = grafana.sops.templates."grafana-contact-points.yaml";
in
assert lib.assertMsg (lib.all (k: lib.elem "${k}-${fixtureApp}" uids) [
  "loki"
  "tempo"
  "pyroscope"
]) "the fixture app lacks a tenant datasource";
assert lib.assertMsg (inline == [ ]) (
  lib.concatMapStringsSep "\n" (h: "${h.uid}: ${h.key} is inline in the store") inline
);
assert lib.assertMsg (
  !lib.any (lib.hasInfix "secureJsonData") grafana.warnings
) "grafana's module still warns of a secureJsonData leak";
assert lib.assertMsg (
  !lib.hasPrefix builtins.storeDir grafana.services.grafana.provision.alerting.contactPoints.path
) "the contact points are read from the store";
assert lib.assertMsg (lib.all (
  s: lib.hasInfix grafana.sops.placeholder.${s} template.content
) contactPointSecrets) "the contact points' template does not take every secret from sops";
pkgs.runCommand "datasource-secrets" { } ''
  ${lib.concatMapStrings (h: ''
    test "$(cat ${h.path})" = ${lib.escapeShellArg (tenantExpectedOf h.uid)} || {
      echo "${h.uid}: its ${h.key} file holds $(cat ${h.path})"
      exit 1
    }
  '') headers}
  touch $out
''
