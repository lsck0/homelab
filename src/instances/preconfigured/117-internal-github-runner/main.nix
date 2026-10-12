# ci: github actions runners and the forgejo runner (lib/forgejo-runner.nix), each trust level its own user
# with its own rootless docker (modules/rootless-docker.nix). Nothing here runs a job as root, and no job can use the nix daemon.
#
# The github repos are public: anyone can open a pull request that changes a workflow to `runs-on: self-hosted`,
# so a runner here takes strangers' code. Each repo's runner is therefore its own user, wiped before every job
# (home, images, volumes, caches, user units), reaching the internet and the lab's dns and nothing else inside;
# it holds no cache or registry credential. A repo gets a runner only when its workflows target self-hosted, and
# exactly one: the per-job wipe needs the user to itself. The subuid range follows the uid.
{ config, lib, pkgs, inputs, inventory, site, upstream, ... }:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # ADD OR REMOVE A REPO HERE, with its runner user's fixed uid (2010 up): one runner each, see the header
  repos = {
    # the scheduled benchmarks (scheduled.yml, vars.BENCH_RUNNER)
    "lsck0/nyangine" = { uid = 2010; };
  };

  # see nixpkgs-unstable in flake.nix
  runnerPackage = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;
  # 2.337.0 dropped node20
  nodeRuntimes = [ "node24" ];
  # a job's ceiling; the listener restarts when it ends, and an idle listener this often
  jobRuntimeMax = "3h";
  restartDelayS = 10;
  # the module takes only ghp_/github_pat_ as a pat, so mint a registration token per start
  regTokenDir = "/run/github-runner-regtoken";
  # the module's StateDirectory root, github-runner/<name>
  stateRoot = "/var/lib/github-runner";
  # a runner that skipped its start for a github outage starts again this long after
  outageRetry = "15min";
  # ExecCondition: 1 to 254 skip the start without a failure, 255 fails it
  conditionFailed = 255;
  # the start includes the mint's retries and backoff (modules/upstream), several minutes during a github blip
  startTimeout = "10min";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  nameOf = repo: lib.toLower (lib.last (lib.splitString "/" repo));
  userOf = repo: "gh-${nameOf repo}";
  regTokenFile = repo: "${regTokenDir}/${nameOf repo}";

  # an ExecCondition: github down skips the start (the resume timer retries), any other failure fails it
  mintToken = repo: pkgs.writeShellScript "github-runner-${nameOf repo}-mint-token" ''
    set -uo pipefail
    umask 077
    unavailable=${toString upstream.unavailable}
    failed=${toString conditionFailed}
    answer=${regTokenDir}/${nameOf repo}.answer
    trap 'rm -f "$answer"' EXIT
    status=0
    ${upstream.run} github ${pkgs.curl}/bin/curl -sSf --max-time 30 -X POST -o "$answer" \
      -H @${config.sops.templates."github-runner-auth".path} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${repo}/actions/runners/registration-token" || status=$?
    [ "$status" -ne "$unavailable" ] || exit "$status"
    if [ "$status" -ne 0 ] || ! ${pkgs.jq}/bin/jq -je .token "$answer" > ${regTokenFile repo}; then
      exit "$failed"
    fi
  '';

  runner = repo: let daemon = config.homelab.rootlessDocker.${userOf repo}; in {
    enable = true;
    package = runnerPackage;
    inherit nodeRuntimes;
    url = "https://github.com/${repo}";
    name = "vm-117-${nameOf repo}";
    tokenFile = regTokenFile repo;
    # one job per registration; the module then cleans the runner's state and work dirs
    ephemeral = true;
    # take over a stale same-name registration
    replace = true;
    extraLabels = [ "nixos" "homelab" ];
    user = userOf repo;
    group = userOf repo;
    # tools workflows expect on PATH; no nix: the daemon refuses these users
    extraPackages = with pkgs; [
      bash coreutils findutils gnugrep gnused gnutar gzip xz which
      git gh curl jq
      docker docker-compose
      gnumake gcc pkg-config
      nodejs python3
    ];
    # steps build and run containers on the repo user's own rootless daemon
    extraEnvironment = {
      DOCKER_HOST = daemon.dockerHost;
      DOCKER_BUILDKIT = "1";
    };
    serviceOverrides = {
      # "+": as root, outside the sandbox: a registration token from sops, then the user starts from nothing
      ExecCondition = "+${mintToken repo}";
      ExecStartPre = lib.mkBefore [ "+${daemon.resetScript}" ];
      TimeoutStartSec = startTimeout;
      # "-": unconfigure.sh deletes the file
      InaccessiblePaths = lib.mkForce [ "-${regTokenFile repo}" "-${stateRoot}/${nameOf repo}/.current-token" ];
      Slice = daemon.slice;
      RuntimeMaxSec = jobRuntimeMax;
      Restart = lib.mkForce "always";
      RestartSec = restartDelayS;
      # the rootless socket lives under /run/user, which the module's default hides
      ProtectHome = "read-only";
    };
  };
in {
  imports = [
    ../../../modules/rootless-docker.nix
    ./lib/forgejo-runner.nix
  ];

  homelab.rootlessDocker = lib.mapAttrs' (repo: r: lib.nameValuePair (userOf repo) {
    inherit (r) uid;
    ephemeral = true;
    # no labAccess: a job reaches the internet and the host's resolvers, never a lab service
  }) repos;

  # the runners' jobs could otherwise build fixed-output derivations, which run as nixbld with the network
  nix.settings.allowed-users = [ "root" ];

  # mints one-use registration tokens (fine-grained: Administration read and write on the repos above); root's alone
  sops.secrets.github-runner-token = { };
  # a header file keeps the token off curl's argv
  sops.templates."github-runner-auth".content = "Authorization: Bearer ${config.sops.placeholder.github-runner-token}\n";

  services.github-runners = lib.mapAttrs' (repo: _: lib.nameValuePair (nameOf repo) (runner repo)) repos;

  # a runner whose start a github outage skipped (ExecCondition) is no failure and no restart: this starts it again
  systemd.timers = lib.mapAttrs' (repo: _: lib.nameValuePair "github-runner-${nameOf repo}-resume" {
    wantedBy = [ "timers.target" ];
    timerConfig = { Unit = "github-runner-${nameOf repo}.service"; OnUnitInactiveSec = outageRetry; };
  }) repos;

  systemd.tmpfiles.rules = [
    "d ${regTokenDir} 0700 root root -"
    # the runners' StateDirectory parent: a dropped uid's 0700 copy kept the runner users out (crash loop)
    "d ${stateRoot} 0755 root root -"
  ];

  # registrations of runners no longer declared hold stale credentials
  system.activationScripts.github-runner-prune = ''
    for dir in ${stateRoot}/*; do
      [ -e "$dir" ] || continue
      case ''${dir##*/} in ${lib.concatStringsSep "|" (map nameOf (lib.attrNames repos))}) continue ;; esac
      rm -rf "$dir"
      echo "github-runner: removed $dir, no declared runner uses it"
    done
  '';
}
