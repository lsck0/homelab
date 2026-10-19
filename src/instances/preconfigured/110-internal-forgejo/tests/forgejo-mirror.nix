# lib/forgejo-mirror.nu against stand-ins of github, forgejo and modules/upstream: a github outage skips the run
# with the upstream's status before forgejo is touched, a failure of its own fails it, and only a 404 means missing
{ pkgs, lib, ... }:
let
  inherit
    ((import ../../../../modules/upstream {
      inherit lib pkgs;
      lab.upstreams = { };
    })._module.args.upstream
    )
    unavailable
    ;
  owner = "luca";
  mirror = pkgs.writers.writeNu "forgejo-mirror" ../lib/forgejo-mirror.nu;

  # GITHUB: up, down, or flaky (lists, then the probe finds it down); FORGEJO_HAS: yes, no, or error (a 500);
  # MIGRATE: ok or fail. Every method and url is logged to $CALLS; no token may reach argv.
  curlStub = pkgs.writeShellScriptBin "curl" ''
    url="" method=GET out=/dev/stdout write=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -X) method=$2; shift ;;
        -o) out=$2; shift ;;
        -w) write=$2; shift ;;
        http*) url=$1 ;;
        *-token*) echo "token on argv: $1" >&2; exit 99 ;;
      esac
      shift
    done
    echo "$method $url" >> "$CALLS"
    answer() { printf '%s' "$2" > "$out"; [ -z "$write" ] || printf '%s' "$1"; }
    case "$url" in
      https://api.github.com/user/repos*page=1)
        [ "$GITHUB" != down ] || exit 7
        echo '[{"name":"r","private":false,"clone_url":"https://github.com/o/r.git","archived":false,"fork":false}]' ;;
      https://api.github.com/*) echo '[]' ;;
      */repos/${owner}/r)
        case "$FORGEJO_HAS" in
          yes) answer 200 '{"mirror":true,"mirror_interval":"8h0m0s"}' ;;
          no) answer 404 '{"message":"not found"}' ;;
          *) answer 500 '{"message":"internal error"}' ;;
        esac ;;
      */repos/migrate) if [ "$MIGRATE" = ok ]; then answer 201 '{}'; else answer 500 '{}'; fi ;;
      */mirror-sync) answer 200 "" ;;
      *) answer 404 "" ;;
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

  cases = {
    mirrored = {
      github = "up";
      forgejoHas = "yes";
      migrate = "ok";
      status = 0;
      touchesForgejo = true;
      migrates = false;
    };
    created = {
      github = "up";
      forgejoHas = "no";
      migrate = "ok";
      status = 0;
      touchesForgejo = true;
      migrates = true;
    };
    outage = {
      github = "down";
      forgejoHas = "yes";
      migrate = "ok";
      status = unavailable;
      touchesForgejo = false;
      migrates = false;
    };
    outage-mid-run = {
      github = "flaky";
      forgejoHas = "no";
      migrate = "fail";
      status = unavailable;
      touchesForgejo = true;
      migrates = true;
    };
    own-failure = {
      github = "up";
      forgejoHas = "no";
      migrate = "fail";
      status = 1;
      touchesForgejo = true;
      migrates = true;
    };
    forgejo-error = {
      github = "up";
      forgejoHas = "error";
      migrate = "ok";
      status = 1;
      touchesForgejo = true;
      migrates = false;
    };
  };

  caseScript = name: c: ''
    : > calls
    status=0
    GITHUB=${c.github} FORGEJO_HAS=${c.forgejoHas} MIGRATE=${c.migrate} CALLS=$PWD/calls \
      ${mirror} > ${name}.log 2>&1 || status=$?
    touched=false migrated=false
    if grep -q ' http://forgejo' calls; then touched=true; fi
    if grep -q '^POST .*/repos/migrate' calls; then migrated=true; fi
    if [ "$status" != ${toString c.status} ] || [ "$touched" != ${lib.boolToString c.touchesForgejo} ] \
      || [ "$migrated" != ${lib.boolToString c.migrates} ]; then
      echo "FAIL ${name}: exit $status, forgejo touched $touched, migrated $migrated;" \
        "want ${toString c.status}, ${lib.boolToString c.touchesForgejo}, ${lib.boolToString c.migrates}"
      cat ${name}.log calls
      failed=1
    fi
  '';
in
pkgs.runCommand "forgejo-mirror"
  {
    nativeBuildInputs = [
      curlStub
      pkgs.coreutils
    ];
  }
  ''
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
