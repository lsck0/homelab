# every textfile a host's units write is in its homelab.textfiles, or activation deletes it (modules/textfile.nix)
#
# Reads the units' own text: a path in textfileDir, directly or through a shell variable set to it. A writer inside a
# store script, or one naming the file only at runtime ($1), is out of its sight.
{ lib, configs, ... }:
let
  unitText = s: lib.concatStringsSep "\n" (lib.flatten [
    (s.script or "") (s.preStart or "") (s.postStart or "")
    (map (k: s.serviceConfig.${k} or [ ]) [ "ExecStartPre" "ExecStart" "ExecStartPost" "ExecStopPost" ])
  ]);

  # the file names after `prefix/`, a shell variable in one standing for any text
  namesAfter = text: prefix: map (m: lib.head m)
    (lib.filter lib.isList (builtins.split "${lib.escapeRegex prefix}/([A-Za-z0-9_\"\${}$-]+)\\.prom" text));
  wildcard = name: let parts = builtins.split "\\$[{]?[A-Za-z0-9_]+[}]?" (lib.replaceStrings [ "\"" ] [ "" ] name); in
    lib.concatStrings (map (p: if lib.isList p then "*" else p) parts);

  written = config: let
    dir = config.homelab.textfileDir;
    text = lib.concatMapStringsSep "\n" unitText (lib.attrValues config.systemd.services);
    variables = map lib.head (lib.filter lib.isList (builtins.split "([A-Za-z_]+)=${lib.escapeRegex dir}[^/]" text));
    prefixes = [ dir ] ++ map (v: "$" + v) variables;
  in lib.filter (name: name != "*") (lib.unique (map wildcard (lib.concatMap (namesAfter text) prefixes)));

  covers = pattern: name: pattern == name
    || (lib.hasSuffix "*" pattern && lib.hasPrefix (lib.removeSuffix "*" pattern) name);
in
lib.concatLists (lib.mapAttrsToList (host: config:
  map (name: "${host}: a unit writes ${config.homelab.textfileDir}/${name}.prom, which homelab.textfiles does not name")
    (lib.filter (name: !(lib.any (pattern: covers pattern name) config.homelab.textfiles)) (written config))
) configs)
