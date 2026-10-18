# the rule a server's name obeys: one dns label below *.mc, which also names its unit, data dir and world, and
# none of the guest's own mc-layout, mc-gate and mc-state
{ lib }:
let
  # one dns label: lowercase letters and digits, hyphens inside (rfc 1123)
  labelPattern = "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
  reserved = [ "layout" "gate" "state" ];

  # a name -> what is wrong with it, or null
  problem = name:
    if builtins.match labelPattern name == null then
      "server ${builtins.toJSON name}: a server name is one dns label, the label below *.mc a player dials"
    else if lib.elem name reserved then
      "server ${name}: the name is taken by the guest's own mc-${name}"
    else null;
in {
  inherit problem;

  # the declared servers -> their names, or a throw listing every name that breaks the rule
  check = servers:
    let
      names = lib.attrNames servers;
      problems = lib.filter (p: p != null) (map problem names);
    in
    lib.throwIf (problems != [ ]) ("214-external-minecraft: " + lib.concatStringsSep "; " problems) names;
}
