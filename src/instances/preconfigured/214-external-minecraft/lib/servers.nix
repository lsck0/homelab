# the servers vm-214 may declare, and the rule their names obey (R-070)
#
# A name is one dns label, because it is the label below the wildcard host *.mc a player dials, and it names the
# server's unit, its data dir and its world. Three labels are taken by the guest's own units and files, so a server
# may not use them: mc-layout, mc-gate and the gate's state.
#
#   servers = import ./lib/servers.nix { inherit lib; };
#   servers.check { cobblemon = { }; }   # the names, or a throw naming every bad one
{ lib }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # one dns label: lowercase letters and digits, hyphens inside (rfc 1123)
  labelPattern = "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
  reserved = [ "layout" "gate" "state" ];

  # -----------------------------------------------------------------------------
  # FUNCTIONS
  # -----------------------------------------------------------------------------

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
