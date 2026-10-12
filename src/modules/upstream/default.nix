# surviving a third-party outage: every call to a service outside the lab (src/lab/upstreams.nix) goes through
# `upstream`, a module argument of every host:
#
#   ${upstream.run} aur git clone https://aur.archlinux.org/foo.git      a call: retried, then classified
#   ${upstream.run} aur                                                 a probe alone, before a run that needs it
#   serviceConfig.SuccessExitStatus = [ upstream.unavailable ];          an outage is no failed unit
#
# After the last attempt the probe url decides: down -> "<name> unavailable", exit `unavailable`, the caller keeps its
# last state; up -> the command's own status. UPSTREAM_{ATTEMPTS,BACKOFF_S,TIMEOUT_S} override the defaults.
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
      unavailable=${toString unavailable}

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
      exit "$unavailable"
    '';
  };
  # an image registry's host -> its upstream name
  registries = lib.mapAttrs' (name: u: lib.nameValuePair u.registry name) (lib.filterAttrs (_: u: u ? registry) lab.upstreams);
  dockerHub = "docker.io";
  # docker's reference rule: a first component with a dot or a colon, or localhost, is a registry, else docker hub
  registryOf = image: let
    parts = lib.splitString "/" image;
    first = lib.head parts;
  in if lib.length parts > 1 && (lib.hasInfix "." first || lib.hasInfix ":" first || first == "localhost") then first else dockerHub;
in {
  # retry and probeTimeoutS: for callers implementing the same contract (core/140-internal-swarm/lib/app-builder.py)
  _module.args.upstream = {
    run = lib.getExe run;
    inherit unavailable registries;
    retry = { inherit attempts backoffS probeTimeoutS; };
    # the upstream an image is pulled from, null when it is none of lab/upstreams.nix (the lab's own registry)
    ofImage = image: registries.${registryOf image} or null;
  };
}
