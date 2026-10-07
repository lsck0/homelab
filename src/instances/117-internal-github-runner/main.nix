# ci: github actions runners and the forgejo runner (lib/forgejo-runner.nix), each trust level its own user
# with its own rootless docker (modules/rootless-docker.nix). Nothing here runs a job as root, and no job can use the nix daemon.
#
# The github repos are public: anyone can open a pull request that changes a workflow to `runs-on: self-hosted`,
# so a runner here takes strangers' code. Each repo's runner is therefore its own user, wiped before every job
# (home, images, volumes, caches, user units), reaching the internet and the lab's dns and nothing else inside;
# it holds no cache or registry credential. A repo gets a runner only when its workflows target self-hosted, and
# exactly one: the per-job wipe needs the user to itself. The subuid range follows the uid.
{ config, lib, pkgs, inputs, inventory, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };

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

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  nameOf = repo: lib.toLower (lib.last (lib.splitString "/" repo));
  userOf = repo: "gh-${nameOf repo}";
  regTokenFile = repo: "${regTokenDir}/${nameOf repo}";

  mintToken = repo: pkgs.writeShellScript "github-runner-${nameOf repo}-mint-token" ''
    set -euo pipefail
    umask 077
    ${pkgs.curl}/bin/curl -sSf -X POST \
      -H @${config.sops.templates."github-runner-auth".path} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${repo}/actions/runners/registration-token" \
      | ${pkgs.jq}/bin/jq -re .token \
      | ${pkgs.coreutils}/bin/tr -d '\n' > ${regTokenFile repo}
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
      # "+": as root, outside the sandbox: the user starts from nothing, then a registration token from sops
      ExecStartPre = lib.mkBefore [ "+${daemon.resetScript}" "+${mintToken repo}" ];
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
    ../../modules/rootless-docker.nix
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

  systemd.tmpfiles.rules = [
    "d ${regTokenDir} 0700 root root -"
    # the runners' StateDirectory parent, whoever made it first; ephemeral state only, so boot clears dropped runners
    "D ${stateRoot} 0755 root root -"
  ];
}
