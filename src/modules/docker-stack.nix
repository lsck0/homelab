{ config, lib, pkgs, retry, ... }:
let
  cfg = config.homelab.swarm;

  stackFile = name: pkgs.writeText "stack-${name}.yaml" cfg.stacks.${name};

  # log in to registries, then deploy all stacks
  deployScript = pkgs.writeShellScript "swarm-deploy" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.gnugrep pkgs.gawk ]}"
    rc=0

    # skip rolled-back builds, else update/rollback loops forever
    rolled_back_build() { # stack
      local svc cur prev img digest state
      for svc in $(docker stack services "$1" --format '{{.Name}}' 2>/dev/null); do
        state=$(docker service inspect "$svc" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')
        # never interrupt a running rollout
        case "$state" in updating|rollback_started) echo "$svc: $state, skipping this round"; return 0 ;; esac
        [ "$state" = rollback_completed ] || continue
        # failed digest lives on the failed tasks
        cur=$(docker service inspect "$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
        prev=$(docker service ps "$svc" --no-trunc --format '{{.Image}}|{{.Error}}' \
          | awk -F'|' -v cur="$cur" '$2 != "" && $1 != cur { print $1; exit }')
        [ -n "$prev" ] || continue
        img=''${prev%@*}
        docker pull -q "$img" >/dev/null 2>&1 || continue
        digest=$(docker image inspect "$img" --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep -m1 -F "''${img%:*}@")
        if [ "''${prev#*@}" = "''${digest#*@}" ]; then
          echo "$svc: $img is still the build that was rolled back, not redeploying"
          return 0
        fi
      done
      return 1
    }
    ${lib.concatStrings (lib.mapAttrsToList (registry: auth: ''
      docker login ${registry} --username ${lib.escapeShellArg auth.username} \
        --password-stdin < ${auth.passwordFile} >/dev/null || { echo "login to ${registry} failed"; rc=1; }
    '') cfg.registries)}
    for name in "$@"; do
      rolled_back_build "$name" && continue
      docker stack deploy --detach=true --with-registry-auth --resolve-image always --prune \
        -c "/etc/swarm-stacks/$name.yaml" "$name" || { echo "deploy of $name failed"; rc=1; }
    done
    exit $rc
  '';
in {
  imports = [ ./retry.nix ];

  options.homelab.swarm = {
    enable = lib.mkEnableOption "single-node Docker Swarm with CI-driven stacks";

    stacks = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = ''
        Swarm stacks as inline compose YAML, keyed by stack name. For zero-downtime
        updates give each service a healthcheck and
        `deploy.update_config.order: start-first`.
      '';
    };

    registries = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          username = lib.mkOption { type = lib.types.str; };
          passwordFile = lib.mkOption {
            type = lib.types.str;
            description = "Runtime path to the password/token (e.g. a sops secret).";
          };
        };
      });
      default = {};
      example = lib.literalExpression ''
        { "ghcr.io" = { username = "lsck0"; passwordFile = config.sops.secrets.ghcr-token.path; }; }
      '';
      description = "Credentials for private registries, keyed by registry host. Public images need none.";
    };

    updateInterval = lib.mkOption {
      type = lib.types.str;
      default = "1m";
      description = "How often to check registries for new image digests and roll them out.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    environment.etc = lib.mapAttrs' (name: _:
      lib.nameValuePair "swarm-stacks/${name}.yaml" { source = stackFile name; }
    ) cfg.stacks;

    systemd.services.docker-swarm-init = {
      description = "Initialize Docker Swarm";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      path = [ pkgs.docker pkgs.coreutils pkgs.iproute2 pkgs.gawk ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        ${retry} 30 1 docker info
        # reset any non-active swarm left after reboot
        state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown)
        if [ "$state" != "active" ]; then
          docker swarm leave --force >/dev/null 2>&1 || true
          # init refuses to guess with several addresses
          addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
          docker swarm init ''${addr:+--advertise-addr "$addr"} || true
        fi
        # fail here, not in every deploy
        [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active ] || { echo "swarm is not active"; exit 1; }
      '';
    };

    # on boot and whenever a stack changes
    systemd.services.swarm-deploy = {
      description = "Deploy Swarm stacks";
      after = [ "docker-swarm-init.service" "network-online.target" ];
      requires = [ "docker-swarm-init.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = map stackFile (lib.attrNames cfg.stacks);
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${deployScript} ${lib.concatStringsSep " " (lib.attrNames cfg.stacks)}";
      };
    };

    # new digest behind a tag rolls an update
    systemd.services.swarm-update = {
      description = "Roll out new images for Swarm stacks";
      after = [ "swarm-deploy.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployScript} ${lib.concatStringsSep " " (lib.attrNames cfg.stacks)}";
      };
    };
    systemd.timers.swarm-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = cfg.updateInterval; };
    };
  };
}
