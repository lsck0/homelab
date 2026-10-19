# a run a deploy may not cut (restartIfChanged = false) never hangs on a nas mount unit: the automount's idle expiry
# and a remount stop the mount, and RequiresMountsFor's Requires= stops the run with it; it requires the automount
{ lib, configs, ... }:
lib.concatLists (
  lib.mapAttrsToList (
    name: config:
    let
      under = path: lib.any (m: path == m || lib.hasPrefix "${m}/" path) (lib.attrNames config.homelab.nasMounts);
      longRuns = lib.filterAttrs (_: s: !s.restartIfChanged) config.systemd.services;
    in
    lib.concatLists (
      lib.mapAttrsToList (
        unit: s:
        map (
          path: "${name}: ${unit} outlives deploys yet RequiresMountsFor the nas mount ${path}, which stops it with the mount"
        ) (lib.filter under (lib.toList (s.unitConfig.RequiresMountsFor or [ ])))
      ) longRuns
    )
  ) configs
)
