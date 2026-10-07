# ntfy-users-prune's selection (lib/users-prune.awk), table by table: each `ntfy user list` below and the accounts it
# must remove. The listings are ntfy 2.14's format (cmd/access.go showUsers).
{ pkgs, lib, ... }:
let
  declared = [ "luca" "grafana" "desktop" ];

  cases = [
    { name = "a hand-made account goes";
      listing = ''
        user luca (role: admin, tier: none, server config)
        - read-write access to all topics (admin role)
        user stale (role: user, tier: none)
        - no topic-specific permissions
      '';
      removed = [ "stale" ]; }
    { name = "a declared account ntfy has not marked yet stays";
      listing = ''
        user grafana (role: user, tier: none)
        - write-only access to topic homelab-alerts
      '';
      removed = [ ]; }
    { name = "an account of the server config stays, declared or not (the server removes it once undeclared)";
      listing = ''
        user desktop (role: user, tier: none, server config)
        - read-only access to topic homelab-alerts (server config)
        user retired (role: user, tier: none, server config)
        - no topic-specific permissions
      '';
      removed = [ ]; }
    { name = "the anonymous user and the grant lines are no accounts";
      listing = ''
        user * (role: anonymous, tier: none)
        - no topic-specific permissions
        - no access to any (other) topics (server config)
      '';
      removed = [ ]; }
    { name = "a name containing a declared one is its own account";
      listing = ''
        user luca2 (role: user, tier: none)
        user lucas (role: user, tier: pro)
      '';
      removed = [ "luca2" "lucas" ]; }
    { name = "an empty user database removes nothing";
      listing = "";
      removed = [ ]; }
  ];

  caseScript = c: ''
    got=$(printf '%s' ${lib.escapeShellArg c.listing} | awk -v declared=${lib.escapeShellArg (toString declared)} -f ${../lib/users-prune.awk})
    want=${lib.escapeShellArg (lib.concatStringsSep "\n" c.removed)}
    if [ "$got" != "$want" ]; then
      echo "FAIL ${c.name}: removed [$got], expected [$want]"; failed=1
    else
      echo "ok   ${c.name}"
    fi
  '';
in
pkgs.runCommand "ntfy-users-prune" { nativeBuildInputs = [ pkgs.gawk ]; } ''
  failed=0
  ${lib.concatMapStrings caseScript cases}
  [ "$failed" = 0 ]
  touch $out
''
