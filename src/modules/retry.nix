# retrying commands, and the setup units built on them
#
# `retry` runs a command until it succeeds, for the waits of a setup script (an app's port answering, a file
# appearing). `setupUnit` is the one shape of a unit that configures an app through its api after it started and
# exports what the app minted (an api key) to the token dirs: a oneshot that retries forever, because what it waits
# for (the app, the nas, a peer guest) comes up in no fixed order at boot, and that holds the token helpers below.
# Every host gets both as module arguments:
#
#   systemd.services.foo-setup = setupUnit {
#     description = "Configure foo and export its API key";
#     after = [ "podman-foo.service" ];
#     path = [ pkgs.curl pkgs.jq ];
#     script = ''
#       ${retry} 90 2 curl -sf http://127.0.0.1:80/health
#       curl -sf ... | jq -j .apiKey | token_write foo-key
#     '';
#   };
#
# Token helpers in every setupUnit script (modules/tokens has the dirs):
#   token_write <name>          the value on stdin becomes this host's <name>.token, renamed into its own dir and
#                               rewritten only when it changed; refuses an empty value or one that is no token
#   token_read <name>           a token this host reads or mints, refusing a value that is no token
# Writes go to the real file in tokens.ownDir, never through the links in tokens.dir: a rename or `rm` through a
# link replaces the link with a local file, and the nas copy, which every consumer reads, goes stale.
{ config, lib, pkgs, ... }:
let
  tokens = config.homelab.tokens;

  # a setup that fails waits this long before the next try: long enough not to hammer an app that is still
  # starting, short enough that a guest converges within a minute of what it waits for
  setupRetryIntervalS = 30;
  # what a token may contain: api keys, jwts, hex and base64. No whitespace or quotes, so a value can never
  # smuggle a second line into an env file or a quote into a config (homepage, janitorr render them)
  tokenPattern = "^[A-Za-z0-9._~+/=-]+$";

  retry = pkgs.writeShellScript "retry" ''
    if [ "$#" -lt 3 ] || ! [ "$1" -gt 0 ] 2>/dev/null || ! [ "$2" -ge 0 ] 2>/dev/null; then
      echo "usage: retry <attempts> <interval seconds> <command...>" >&2
      exit 2
    fi
    attempts=$1 interval=$2; shift 2
    last=$(${pkgs.coreutils}/bin/mktemp)
    trap '${pkgs.coreutils}/bin/rm -f "$last"' EXIT
    for ((i = 1; i <= attempts; i++)); do
      "$@" >/dev/null 2>"$last" && exit 0
      (( i < attempts )) && ${pkgs.coreutils}/bin/sleep "$interval"
    done
    # the last attempt's own words, else the journal only says that it gave up
    echo "retry: gave up after $attempts attempts: $*: $(${pkgs.coreutils}/bin/tail -c 500 "$last")" >&2
    exit 1
  '';

  tokenHelpers = ''
    token_read() { # <name>
      local value re='${tokenPattern}'
      value=$(${pkgs.coreutils}/bin/cat "${tokens.dir}/$1.token") || return 1
      [[ $value =~ $re ]] || { echo "token_read: $1 holds no token, refusing it" >&2; return 1; }
      printf '%s' "$value"
    }
  '' + lib.optionalString (tokens.ownDir != null) ''
    token_write() { # <name>, the value on stdin
      local own="${tokens.ownDir}" value tmp re='${tokenPattern}'
      value=$(${pkgs.coreutils}/bin/cat)
      [[ $value =~ $re ]] || { echo "token_write: refusing an empty or malformed value for $1" >&2; return 1; }
      printf '%s' "$value" | ${pkgs.diffutils}/bin/cmp -s - "$own/$1.token" && return 0
      tmp=$(${pkgs.coreutils}/bin/mktemp "$own/.$1.XXXXXX")
      printf '%s' "$value" > "$tmp"
      # 0644: hermes reads every token as its own user (lab-token on vm-114)
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$own/$1.token"
      echo "token $1 exported"
    }
  '';

  setupUnit = unit: lib.recursiveUpdate {
    wantedBy = [ "multi-user.target" ];
    # retry forever: what the unit waits for comes up in no fixed order
    startLimitIntervalSec = 0;
    # an lxc mounts nfs at boot, not on access: never write under an empty mountpoint
    unitConfig.RequiresMountsFor = tokens.mountPoints;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = setupRetryIntervalS;
    };
  } (unit // {
    # strict for every setup: an unset name, a failed command or a failed stage of a pipe stops it
    script = "set -euo pipefail\n" + tokenHelpers + unit.script;
  });
in {
  _module.args = { inherit retry setupUnit; };
}
