# the rule a declared server's name obeys (lib/servers.nix), at evaluation time: every accepted name is one
# DNS label the player can dial below *.mc, every refused one throws with a message naming what is wrong.
{ pkgs, lib, ... }:
let
  servers = import ../lib/servers.nix { inherit lib; };

  # a name -> the message its refusal must contain
  refused = {
    layout = "taken by the guest's own mc-layout";
    gate = "taken by the guest's own mc-gate";
    state = "taken by the guest's own mc-state";
    "mc.cobblemon" = "one dns label";
    "Cobblemon" = "one dns label";
    "-cobblemon" = "one dns label";
    "cobblemon-" = "one dns label";
    "cobble_mon" = "one dns label";
    "" = "one dns label";
    "cobblemon*" = "one dns label";
  };

  accepted = [
    "cobblemon"
    "mc"
    "atm10"
    "all-the-mods-10"
    "x"
  ];

  # does `check` accept a one-server declaration of this name?
  accepts = name: (builtins.tryEval (builtins.deepSeq (servers.check { ${name} = { }; }) true)).success;

  refusalProblems = lib.concatLists (
    lib.mapAttrsToList (
      name: expect:
      let
        problem = servers.problem name;
      in
      if problem == null || accepts name then
        [ "the name ${builtins.toJSON name} is accepted, it must be refused" ]
      else
        lib.optional (!(lib.hasInfix expect problem)) (
          "the name ${builtins.toJSON name} is refused"
          + " with ${builtins.toJSON problem}, which does not say ${builtins.toJSON expect}"
        )
    ) refused
  );

  acceptedProblems = lib.concatLists (
    map (name: lib.optional (!(accepts name)) "the name ${builtins.toJSON name} is refused, it must be accepted") accepted
  );

  # the real declaration of several servers passes, and reports every bad name at once
  manyProblems =
    lib.optional
      (builtins.tryEval (
        builtins.deepSeq (servers.check {
          cobblemon = { };
          layout = { };
          "Bad" = { };
        }) true
      )).success
      "a declaration holding layout and Bad is accepted, it must throw";

  problems = refusalProblems ++ acceptedProblems ++ manyProblems;
  report = pkgs.writeText "mc-servers-problems" (lib.concatLines problems);
in
pkgs.runCommand "mc-servers" { } (
  if problems == [ ] then
    ''
      echo "mc-servers: ${toString (lib.length accepted)} accepted,"\
        "${toString (lib.length (lib.attrNames refused))} refused"
      touch $out
    ''
  else
    ''
      cat ${report} >&2
      exit 1
    ''
)
