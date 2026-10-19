# a unit that stays up never RequiresMountsFor a nas mount: the automount's idle expiry and a restart of the nas stop
# the mount, Requires= stops the unit with it, and nothing starts it again. It requires the automount (nasRequires,
# modules/nas.nix). Staying up: a service that is no oneshot, a RemainAfterExit oneshot, one another unit requires or a
# deploy may not cut, and every path unit, which requires the mount of each path it watches.
{ lib, configs, ... }:
lib.concatLists (
  lib.mapAttrsToList (
    name: config:
    let
      onNas = path: lib.any (m: path == m || lib.hasPrefix "${m}/" path) (lib.attrNames config.homelab.nasMounts);
      mountsOf = unit: lib.filter onNas (lib.toList (unit.unitConfig.RequiresMountsFor or [ ]));
      staysUp =
        s:
        (s.serviceConfig.Type or "simple") != "oneshot"
        || lib.elem (s.serviceConfig.RemainAfterExit or false) [
          true
          "yes"
        ]
        || s.requiredBy != [ ]
        || !s.restartIfChanged;
      watchKeys = [
        "PathExists"
        "PathExistsGlob"
        "PathChanged"
        "PathModified"
        "DirectoryNotEmpty"
      ];
      watchedOf = p: lib.concatMap (k: lib.toList (p.pathConfig.${k} or [ ])) watchKeys;
      violation =
        kind: unit: path:
        "${name}: ${kind} ${unit} stays up yet RequiresMountsFor the nas mount of ${path}";
    in
    lib.concatLists (
      lib.mapAttrsToList (unit: s: map (violation "service" unit) (mountsOf s)) (
        lib.filterAttrs (_: s: s.enable && staysUp s) config.systemd.services
      )
      ++ lib.mapAttrsToList (unit: p: map (violation "path unit" unit) (mountsOf p ++ lib.filter onNas (watchedOf p))) (
        lib.filterAttrs (_: p: p.enable) config.systemd.paths
      )
    )
  ) configs
)
