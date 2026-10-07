# surviving a third-party outage: every call to a service outside the lab (src/lab/upstreams.nix) goes through
# `upstream`, a module argument of every host:
#
#   ${upstream.run} aur git clone https://aur.archlinux.org/foo.git      a call: retried, then classified
#   ${upstream.run} aur                                                 a probe alone, before a run that needs it
#   serviceConfig.SuccessExitStatus = [ upstream.unavailable ];          an outage is no failed unit
#
# Each attempt runs under a time bound; a failed one is retried after a backoff that doubles. When the last attempt
# fails too, the upstream's probe url decides: unreachable or answering 5xx, the upstream is down, `run` logs
# "<name> unavailable" and exits `unavailable` (EX_TEMPFAIL), and the caller keeps its last good state and tries again
# on its next run; reachable, the failure is the caller's own and its status passes through. vm-105 probes every
# upstream itself and raises one "<name> unavailable" alert per upstream, whichever hosts depend on it.
#
# UPSTREAM_ATTEMPTS, UPSTREAM_BACKOFF_S and UPSTREAM_TIMEOUT_S override the defaults (tests, a long clone).
{ lib, pkgs, lab, ... }:
let
  # three retries over about two minutes ride out a blip; a real outage is the next run's
  attempts = 4;
  backoffS = 15;
  # one attempt's bound; a caller passes a longer one for a large transfer
  attemptTimeoutS = 600;
  probeTimeoutS = 10;
  # sysexits EX_TEMPFAIL: the upstream is down, the caller did nothing wrong
  unavailable = 75;

  run = pkgs.writeShellApplication {
    name = "upstream";
    runtimeInputs = [ pkgs.coreutils pkgs.curl ];
    text = ''
      if [ "$#" -lt 1 ]; then
        echo "usage: upstream <name> [command...]" >&2
        exit 2
      fi
      name=$1
      shift
      declare -A urls
      ${lib.concatStrings (lib.mapAttrsToList (n: u: "urls[${n}]=${lib.escapeShellArg u.url}\n") lab.upstreams)}
      url=''${urls[$name]:-}
      [ -n "$url" ] || { echo "upstream: no upstream $name in src/lab/upstreams.nix" >&2; exit 2; }
      attempts=''${UPSTREAM_ATTEMPTS:-${toString attempts}}
      backoff=''${UPSTREAM_BACKOFF_S:-${toString backoffS}}
      limit=''${UPSTREAM_TIMEOUT_S:-${toString attemptTimeoutS}}

      answer=
      reachable() {
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time ${toString probeTimeoutS} "$url") && [[ $code =~ ^[1-4][0-9][0-9]$ ]] && return 0
        answer="answered ''${code:-nothing}"
        return 1
      }

      status=0
      for ((attempt = 1; ; attempt++)); do
        if [ "$#" -eq 0 ]; then
          reachable && exit 0
        else
          status=0
          timeout "$limit" "$@" || status=$?
          [ "$status" -eq 0 ] && exit 0
        fi
        ((attempt >= attempts)) && break
        echo "upstream: $name: attempt $attempt failed, next in $backoff s" >&2
        sleep "$backoff"
        backoff=$((backoff * 2))
      done
      if [ "$#" -gt 0 ] && reachable; then
        exit "$status"
      fi
      echo "$name unavailable ($url $answer), keeping the last state" >&2
      exit ${toString unavailable}
    '';
  };
in {
  _module.args.upstream = { run = lib.getExe run; inherit unavailable; };
}
