{ config, lib, pkgs, inputs, ... }:
let
  # see the nixpkgs-unstable comment in flake.nix
  runnerPackage = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;

  # ───────────────────────────────────────────────────────────────────────────
  # ADD OR REMOVE A REPO HERE.
  repos = {
    "lsck0/homelab" = 2;
    "lsck0/arch-dotfiles" = 1;
    "lsck0/webapp-template" = 1;
  };

  # a token with Administration: read and write on those repos (sops: github-runner-token)
  apiTokenFile = config.sops.secrets.github-runner-token.path;

  slug = repo: lib.replaceStrings [ "/" ] [ "-" ] (lib.toLower repo);

  # The module treats the token file as a PAT only when it starts with "ghp_" or "github_pat_"
  regTokenDir = "/run/github-runner-regtoken";
  regTokenFile = name: "${regTokenDir}/${name}";

  mintToken = name: repo: pkgs.writeShellScript "github-runner-${name}-mint-token" ''
    set -euo pipefail
    umask 077
    ${pkgs.curl}/bin/curl -sSf -X POST \
      -H "Authorization: Bearer $(${pkgs.coreutils}/bin/cat ${apiTokenFile})" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${repo}/actions/runners/registration-token" \
      | ${pkgs.jq}/bin/jq -re .token \
      | ${pkgs.coreutils}/bin/tr -d '\n' > ${regTokenFile name}
  '';

  # name -> owner/repo, for the minting script above
  runnerRepos = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" repo) (lib.range 1 count)
  ) repos));

  runners = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" {
      enable = true;
      package = runnerPackage;
      # 2.337.0 dropped node20; the module's default would fail its assertion.
      nodeRuntimes = [ "node24" ];
      url = "https://github.com/${repo}";
      name = "vm-117-${slug repo}-${toString n}";
      tokenFile = regTokenFile "${slug repo}-${toString n}";

      # one job per runner process, then it de-registers
      ephemeral = true;

      # take over a stale registration with the same name instead of refusing to start
      replace = true;

      extraLabels = [ "nixos" "homelab" ];
      user = "github-runner";
      group = "github-runner";
      # No workDir: it defaults to the runtime dir, and setting it to the state dir made

      # what a workflow can reasonably expect on the PATH without installing it.
      extraPackages = with pkgs; [
        bash coreutils findutils gnugrep gnused gnutar gzip xz which
        git gh curl jq
        docker docker-compose
        nix
        gnumake gcc pkg-config
        nodejs python3
      ];

      extraEnvironment = {
        # the internal registry and the Nix cache are reachable from this VM.
        DOCKER_BUILDKIT = "1";
      };

      serviceOverrides = {
        # CI is bursty and this VM is shared: keep one job from starving the rest of the box
        CPUWeight = 50;
        IOWeight = 50;
        MemoryHigh = "2G";
        MemoryMax = "3G";
        # bounds a hung job, but it also stops a listener that has merely been
        # idle for 3h, and ephemeral's Restart=on-success does not cover a
        # timeout, so the unit stayed failed. Restart on any exit instead.
        RuntimeMaxSec = "3h";
        Restart = lib.mkForce "always";
        RestartSec = 10;
        SupplementaryGroups = [ "docker" ];
      };
    }) (lib.range 1 count)
  ) repos));
in {
  networking.hostName = "vm-117";

  # General-purpose GitHub Actions runners, one registration per repo replica.

  users.users.github-runner = {
    isSystemUser = true;
    group = "github-runner";
    home = "/var/lib/github-runner";
    createHome = true;
    # docker for container jobs and `docker build`/`push` to vm-118.
    extraGroups = [ "docker" ];
  };
  users.groups.github-runner = { };

  virtualisation.docker = {
    enable = true;
    # a workflow that leaks images or layers must not fill the disk silently.
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" "--filter" "until=48h" ];
    };
  };

  # the internal registry (vm-118) serves plain HTTP: allow it explicitly rather than making
  virtualisation.docker.daemon.settings.insecure-registries = [
    "10.100.0.118:5000"
    "registry.lsck0.dev"
  ];

  sops.secrets.github-runner-token = {
    owner = "github-runner";
    group = "github-runner";
    mode = "0400";
  };

  services.github-runners = runners;

  systemd.tmpfiles.rules = [
    "d /var/lib/github-runner 0750 github-runner github-runner -"
    "d ${regTokenDir} 0700 root root -"
  ];

  # resolve the lab's own names without going out to Cloudflare.
  networking.hosts = {
    "10.100.0.118" = [ "registry.lsck0.dev" ];
    "10.100.0.115" = [ "git.lsck0.dev" ];
    "10.100.0.111" = [ "sccache.lsck0.dev" ];
  };

  # nothing listens here: the runners connect out to GitHub.
  networking.firewall.allowedTCPPorts = [ ];

  systemd.services = lib.mapAttrs' (n: repo: lib.nameValuePair "github-runner-${n}" {
    serviceConfig = {
      # "+": as root and outside the sandbox, so it can read the sops secret
      ExecStartPre = lib.mkBefore [ "+${mintToken n repo}" ];

      # The module emits these with no "-" prefix, but its own unconfigure.sh pre-start deletes
      InaccessiblePaths = lib.mkForce [
        "-${regTokenFile n}"
        "-/var/lib/github-runner/${n}/.current-token"
      ];
    };
  }) runnerRepos;
}
