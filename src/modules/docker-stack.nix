{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.dockerStack;
  hasGit = cfg.gitRepo != null;
  workDir = "/var/lib/docker-stacks/${cfg.stackName}";
  composeDir = if hasGit then "${workDir}/repo/${cfg.composePath}" else workDir;
  composeFile = "${composeDir}/${cfg.composeFilename}";

  gitCloneScript = pkgs.writeShellScript "docker-stack-git-sync-${cfg.stackName}" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.docker-compose pkgs.coreutils pkgs.diffutils ]}"

    REPO_DIR="${workDir}/repo"
    HASH_FILE="${workDir}/.last-hash"

    # Clone or fetch
    if [ ! -d "$REPO_DIR/.git" ]; then
      git clone ${lib.optionalString (cfg.gitBranch != null) "-b ${cfg.gitBranch}"} \
        "${cfg.gitRepo}" "$REPO_DIR"
    else
      git -C "$REPO_DIR" fetch origin
      BRANCH=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)
      git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
    fi

    # Check if compose file changed
    NEW_HASH=$(sha256sum "${composeFile}" | cut -d' ' -f1)
    OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")

    if [ "$NEW_HASH" != "$OLD_HASH" ]; then
      echo "Compose file changed, redeploying..."
      docker-compose -f "${composeFile}" -p "${cfg.stackName}" pull --quiet
      docker-compose -f "${composeFile}" -p "${cfg.stackName}" up -d --remove-orphans
      echo "$NEW_HASH" > "$HASH_FILE"
    else
      echo "No changes detected."
    fi
  '';
in {
  options.homelab.dockerStack = {
    enable = lib.mkEnableOption "Docker Compose stack deployment";

    stackName = lib.mkOption {
      type = lib.types.str;
      description = "Name for the docker compose project.";
    };

    # Mode 1: inline compose
    composeFile = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Inline Docker Compose YAML content.";
    };

    # Mode 2: git-sourced compose
    gitRepo = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Git repository URL containing the compose file.";
    };

    gitBranch = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Branch to track. Defaults to the repo's default branch.";
    };

    composePath = lib.mkOption {
      type = lib.types.str;
      default = ".";
      description = "Path within the repo to the directory containing the compose file.";
    };

    composeFilename = lib.mkOption {
      type = lib.types.str;
      default = "docker-compose.yaml";
      description = "Exact filename of the compose file (e.g. docker-compose.yaml, compose.yml).";
    };

    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = "How often to poll the git repo for changes (systemd calendar syntax).";
    };

    # Shared options
    registryMirrors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Docker registry mirrors (e.g. internal registry).";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.composeFile != null) != (cfg.gitRepo != null);
          message = "dockerStack: set exactly one of composeFile (inline) or gitRepo (git-sourced).";
        }
      ];

      virtualisation.docker = {
        enable = true;
        daemon.settings = lib.mkIf (cfg.registryMirrors != []) {
          registry-mirrors = cfg.registryMirrors;
          insecure-registries = cfg.registryMirrors;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${workDir} 0750 root root -"
      ];
    }

    # Mode 1: inline compose file
    (lib.mkIf (!hasGit) {
      environment.etc."docker-stacks/${cfg.stackName}/${cfg.composeFilename}".text = cfg.composeFile;

      systemd.services."docker-stack-${cfg.stackName}" = {
        description = "Docker Compose stack: ${cfg.stackName}";
        after = [ "docker.service" "network-online.target" ];
        wants = [ "docker.service" "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f /etc/docker-stacks/${cfg.stackName}/${cfg.composeFilename} -p ${cfg.stackName} up -d --remove-orphans";
          ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f /etc/docker-stacks/${cfg.stackName}/${cfg.composeFilename} -p ${cfg.stackName} down";
        };
      };
    })

    # Mode 2: git-sourced compose file with polling
    (lib.mkIf hasGit {
      environment.systemPackages = [ pkgs.git ];

      # Git SSH key for private repos (optional, place at /var/lib/docker-stacks/<name>/deploy_key)
      programs.ssh.extraConfig = ''
        Host docker-stack-${cfg.stackName}
          IdentityFile ${workDir}/deploy_key
          StrictHostKeyChecking no
      '';

      systemd.services."docker-stack-${cfg.stackName}" = {
        description = "Docker Compose stack (git): ${cfg.stackName}";
        after = [ "docker.service" "network-online.target" ];
        wants = [ "docker.service" "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = gitCloneScript;
        };
      };

      systemd.timers."docker-stack-${cfg.stackName}" = {
        description = "Poll git for ${cfg.stackName} compose changes";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = cfg.pollInterval;
        };
      };
    })
  ]);
}
