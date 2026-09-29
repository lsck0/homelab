{ config, lib, pkgs, inputs, ... }:
let
  # see nixpkgs-unstable in flake.nix
  runnerPackage = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;

  # ADD OR REMOVE A REPO HERE.
  repos = {
    "lsck0/homelab" = 2;
    "lsck0/arch-dotfiles" = 1;
    "lsck0/webapp-template" = 1;
  };

  # needs Administration: read and write on the repos
  apiTokenFile = config.sops.secrets.github-runner-token.path;

  slug = repo: lib.replaceStrings [ "/" ] [ "-" ] (lib.toLower repo);

  # module takes only ghp_/github_pat_ as a pat, so mint
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

  # name -> owner/repo for the minting script
  runnerRepos = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" repo) (lib.range 1 count)
  ) repos));

  runners = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (repo: count:
    map (n: lib.nameValuePair "${slug repo}-${toString n}" {
      enable = true;
      package = runnerPackage;
      # 2.337.0 dropped node20
      nodeRuntimes = [ "node24" ];
      url = "https://github.com/${repo}";
      name = "vm-117-${slug repo}-${toString n}";
      tokenFile = regTokenFile "${slug repo}-${toString n}";

      # one job per process, then de-register
      ephemeral = true;

      # take over a stale same-name registration
      replace = true;

      extraLabels = [ "nixos" "homelab" ];
      user = "github-runner";
      group = "github-runner";
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

      extraEnvironment = {
        # internal registry and nix cache reachable
        DOCKER_BUILDKIT = "1";
      };

      serviceOverrides = {
        # shared vm, keep one job from starving it
        CPUWeight = 50;
        IOWeight = 50;
        MemoryHigh = "2G";
        MemoryMax = "3G";
        # timeout also kills idle listeners, restart always
        RuntimeMaxSec = "3h";
        Restart = lib.mkForce "always";
        RestartSec = 10;
        SupplementaryGroups = [ "docker" ];
      };
    }) (lib.range 1 count)
  ) repos));
in {
  networking.hostName = "vm-117";

  # one github actions runner per repo replica

  users.users.github-runner = {
    isSystemUser = true;
    group = "github-runner";
    home = "/var/lib/github-runner";
    createHome = true;
    # docker jobs and pushes to vm-118
    extraGroups = [ "docker" ];
  };
  users.groups.github-runner = { };

  virtualisation.docker = {
    enable = true;
    # leaked images must not fill the disk
    autoPrune = {
      enable = true;
      dates = "daily";
      flags = [ "--all" "--filter" "until=48h" ];
    };
  };

  # registry (vm-118) is plain http
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

  # lab names without cloudflare
  networking.hosts = {
    "10.100.0.118" = [ "registry.lsck0.dev" ];
    # the ingress, not forgejo itself: only traefik terminates https for it
    "10.100.0.100" = [ "git.lsck0.dev" ];
    "10.100.0.110" = [ "sccache.lsck0.dev" ];
  };

  # runners connect out, nothing listens
  networking.firewall.allowedTCPPorts = [ ];

  systemd.services = lib.mapAttrs' (n: repo: lib.nameValuePair "github-runner-${n}" {
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
