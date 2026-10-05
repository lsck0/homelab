{ config, lib, pkgs, inputs, ... }:
let
  ci = config.homelab.rootlessDocker.ci;
  # what any build on this vm needs inside the lab: the router's dns, and git and the registry on the ingress
  labBasics = [
    { ip = "10.100.0.1"; port = 53; proto = "udp"; }
    { ip = "10.100.0.1"; port = 53; }
    { ip = "10.100.0.100"; port = 443; }
  ];
  ciUser = "ci";

  # see nixpkgs-unstable in flake.nix
  runnerPackage = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;

  # ADD OR REMOVE A REPO HERE.
  repos = {
    "lsck0/homelab" = 2;
    "lsck0/arch-dotfiles" = 1;
    "lsck0/webapp-template" = 1;
    "lsck0/nyangine" = 1;
  };

  # mints one-use registration tokens; needs Administration: read and write on the repos above, nothing else
  apiTokenFile = config.sops.secrets.github-runner-token.path;

  slug = repo: lib.replaceStrings [ "/" ] [ "-" ] (lib.toLower repo);

  # module takes only ghp_/github_pat_ as a pat, so mint
  regTokenDir = "/run/github-runner-regtoken";
  regTokenFile = name: "${regTokenDir}/${name}";

  mintToken = name: repo: pkgs.writeShellScript "github-runner-${name}-mint-token" ''
    set -euo pipefail
    umask 077
    ${pkgs.curl}/bin/curl -sSf -X POST \
      -H @${config.sops.templates."github-runner-auth".path} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${repo}/actions/runners/registration-token" \
      | ${pkgs.jq}/bin/jq -re .token \
      | ${pkgs.coreutils}/bin/tr -d '\n' > ${regTokenFile name}
  '';

  # name -> owner/repo for the minting script
  runnerRepos = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" repo) (lib.range 1 count)
  ) repos));

  runners = lib.mapAttrs (name: repo: {
    enable = true;
    package = runnerPackage;
    # 2.337.0 dropped node20
    nodeRuntimes = [ "node24" ];
    url = "https://github.com/${repo}";
    name = "vm-117-${name}";
    tokenFile = regTokenFile name;

    # one job per process, then de-register
    ephemeral = true;

    # take over a stale same-name registration
    replace = true;

    extraLabels = [ "nixos" "homelab" ];
    user = ciUser;
    group = ciUser;
    # no workDir, the runtime dir default works

    # tools workflows expect on PATH
    extraPackages = with pkgs; [
      bash coreutils findutils gnugrep gnused gnutar gzip xz which
      git gh curl jq
      docker docker-compose
      nix
      gnumake gcc pkg-config
      nodejs python3
    ];

    # steps build and push through ci's rootless daemon
    extraEnvironment = {
      DOCKER_HOST = ci.dockerHost;
      DOCKER_BUILDKIT = "1";
    };

    serviceOverrides = {
      # the cache url carries a password, so it comes from sops, not the nix store
      EnvironmentFile = config.sops.templates."sccache-redis.env".path;
      Slice = ci.slice;
      # timeout also kills idle listeners, restart always
      RuntimeMaxSec = "3h";
      Restart = lib.mkForce "always";
      RestartSec = 10;
      # the rootless socket lives under /run/user, which the module's default hides
      ProtectHome = "read-only";
    };
  }) runnerRepos;
in {
  imports = [
    ../modules/rootless-docker.nix
    ../services/forgejo-runner.nix
    ../services/app-builder.nix
  ];

  # the builder deploys to the swarm manager as well
  homelab.rootlessDocker.appbuild.labAccess = labBasics ++ [ { ip = config.homelab.appBuilder.manager; port = 22; } ];

  networking.hostName = "vm-117";

  # one github actions runner per repo replica, one forgejo runner, all as the unprivileged ci user
  homelab.rootlessDocker.ci = {
    uid = 2000;
    # dns, git and registry through the ingress, the compile cache; nothing else inside the lab
    labAccess = labBasics ++ [ { ip = "10.100.0.110"; port = 6379; } ];
  };

  # lab names without cloudflare; the ingress, not the services: traefik terminates https and gates pushes
  networking.hosts = {
    "10.100.0.100" = [ "git.lsck0.dev" "registry.lsck0.dev" ];
    "10.100.0.110" = [ "sccache.lsck0.dev" ];
  };

  # root alone: steps run as ci and must never read an account-wide token
  sops.secrets.github-runner-token = { };
  # a header file keeps the token off curl's argv
  sops.templates."github-runner-auth".content = "Authorization: Bearer ${config.sops.placeholder.github-runner-token}\n";

  services.github-runners = runners;

  sops.secrets.sccache-redis-pass = { };
  sops.templates."sccache-redis.env" = {
    owner = ciUser;
    content = "SCCACHE_REDIS=redis://:${config.sops.placeholder.sccache-redis-pass}@sccache.lsck0.dev\n";
  };

  systemd.tmpfiles.rules = [
    "d ${regTokenDir} 0700 root root -"
  ];

  # runners connect out, nothing listens
  networking.firewall.allowedTCPPorts = [ ];

  systemd.services = lib.mapAttrs' (n: repo: lib.nameValuePair "github-runner-${n}" {
    wants = [ ci.userUnit ];
    after = [ ci.userUnit ];
    serviceConfig = {
      # "+": root outside the sandbox reads sops
      ExecStartPre = lib.mkBefore [ "+${mintToken n repo}" ];

      # "-" prefix, unconfigure.sh deletes the file
      InaccessiblePaths = lib.mkForce [
        "-${regTokenFile n}"
        "-/var/lib/github-runner/${n}/.current-token"
      ];
    };
  }) runnerRepos;
}
