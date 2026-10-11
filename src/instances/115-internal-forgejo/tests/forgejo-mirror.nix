# lib/forgejo-mirror.sh against stand-ins of github, forgejo and modules/upstream: a github outage skips the run
# with the upstream's status before forgejo is touched, a failure of its own fails it
{ pkgs, lib, ... }:
let
  unavailable = 75;
  owner = "luca";

  # GITHUB: up, down, or flaky (lists, then the probe finds it down); FORGEJO_HAS: yes when the mirror exists;
  # MIGRATE: ok or fail. Every url is logged to $CALLS.
  curlStub = pkgs.writeShellScriptBin "curl" ''
    url=""
    for arg in "$@"; do case "$arg" in http*) url=$arg ;; esac; done
    echo "$url" >> "$CALLS"
    case "$url" in
      https://api.github.com/user/repos*page=1)
        [ "$GITHUB" != down ] || exit 7
        echo '[{"name":"r","private":false,"clone_url":"https://github.com/o/r.git","archived":false,"fork":false}]' ;;
      https://api.github.com/*) echo '[]' ;;
      */repos/${owner}/r) [ "$FORGEJO_HAS" = yes ] || exit 22; echo '{"mirror":true,"mirror_interval":"8h0m0s"}' ;;
      */repos/migrate) [ "$MIGRATE" = ok ] || exit 22 ;;
      */mirror-sync) ;;
      *) exit 22 ;;
    esac
  '';
  # modules/upstream's contract: a probe alone, or a call whose failure the probe classifies
  upstreamStub = pkgs.writeShellScript "upstream" ''
    shift
    unavailable=${toString unavailable}
    up() { [ "$GITHUB" = up ]; }
    if [ "$#" -eq 0 ]; then up || exit "$unavailable"; exit 0; fi
    status=0
    "$@" || status=$?
    if [ "$status" != 0 ] && ! up; then exit "$unavailable"; fi
    exit "$status"
  '';

  # name -> { github; forgejoHas; migrate; status; touchesForgejo }
  cases = {
    mirrored = { github = "up"; forgejoHas = "yes"; migrate = "ok"; status = 0; touchesForgejo = true; };
    created = { github = "up"; forgejoHas = "no"; migrate = "ok"; status = 0; touchesForgejo = true; };
    outage = { github = "down"; forgejoHas = "yes"; migrate = "ok"; status = unavailable; touchesForgejo = false; };
    outage-mid-run = { github = "flaky"; forgejoHas = "no"; migrate = "fail"; status = unavailable; touchesForgejo = true; };
    own-failure = { github = "up"; forgejoHas = "no"; migrate = "fail"; status = 1; touchesForgejo = true; };
  };

  caseScript = name: c: ''
    : > calls
    status=0
    GITHUB=${c.github} FORGEJO_HAS=${c.forgejoHas} MIGRATE=${c.migrate} CALLS=$PWD/calls \
      bash ${../lib/forgejo-mirror.sh} > ${name}.log 2>&1 || status=$?
    touched=false
    if grep -q '^http://forgejo' calls; then touched=true; fi
    if [ "$status" != ${toString c.status} ] || [ "$touched" != ${lib.boolToString c.touchesForgejo} ]; then
      echo "FAIL ${name}: exit $status, forgejo touched $touched; want ${toString c.status}, ${lib.boolToString c.touchesForgejo}"
      cat ${name}.log calls
      failed=1
    fi
  '';
in
pkgs.runCommand "forgejo-mirror" { nativeBuildInputs = [ curlStub pkgs.jq pkgs.gawk pkgs.coreutils ]; } ''
  printf forgejo-token > forgejo.token
  printf github-token > github.token
  export FORGEJO_URL=http://forgejo FORGEJO_OWNER=${owner} MIRROR_INTERVAL=8h
  export FORGEJO_TOKEN_FILE=$PWD/forgejo.token GITHUB_TOKEN_FILE=$PWD/github.token
  export UPSTREAM=${upstreamStub} UPSTREAM_UNAVAILABLE=${toString unavailable}
  failed=0
  ${lib.concatStrings (lib.mapAttrsToList caseScript cases)}
  [ "$failed" = 0 ] || exit 1
  echo "${toString (lib.length (lib.attrNames cases))} cases pass" > $out
''
