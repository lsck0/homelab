# the app catalog's builder: a new commit on an app's branch is built here, parked in the registry and deployed
#
# Runs as `appbuild` against its own rootless docker (modules/rootless-docker.nix), apart from the ci user whose
# jobs run fork pull requests: only this user holds the registry push credential and the key to the swarm
# manager's forced command, and it builds only the branches the catalog names. A push reaches the swarm within
# a minute (`git ls-remote` per app, one request each), rolled out start-first with rollback (scripts/swarm-render.py).
{ config, lib, pkgs, inventory, ... }:
let
  user = "appbuild";
  uid = 2001;
  docker = config.homelab.rootlessDocker.${user};
  stateDir = "/var/lib/app-builder";
  # a push is live within this, plus its build
  pollInterval = "1min";
  textfile = "/var/lib/node-exporter-textfile/app_builder.prom";

  catalog = import ../modules/apps.nix;
  apps = lib.filterAttrs (_: a: a.enable or false) catalog.apps;
  manager = inventory.${toString catalog.swarm.manager}.ip;
  catalogJson = pkgs.writeText "app-builder.json" (builtins.toJSON (lib.mapAttrs (_: a: {
    inherit (a) repo branch;
    stack = a.stack or null;
    build = a.build or { };
    exclude = a.exclude or [ ];
    watch = a.watch or [ ];
  }) apps));

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  builder = pkgs.writeShellScript "app-builder" ''
    exec ${python}/bin/python3 ${../scripts/app-builder.py} ${catalogJson} ${stateDir} ${manager} "$@"
  '';
  # its own registry user: a ci job that reads the ci user's push secret cannot push as the builder
  login = pkgs.writeShellScript "app-builder-login" ''
    docker login registry.lsck0.dev -u builder --password-stdin < ${config.sops.secrets.registry-builder-password.path} >/dev/null
  '';
in {
  options.homelab.appBuilder.manager = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = manager;
    description = "The swarm manager the builder deploys to.";
  };

  config = {
    homelab.rootlessDocker.${user} = {
      inherit uid;
      # rust nightly and node builds; the ci user caps its own share
      memoryMax = "3G";
      buildCacheKeep = "20GB";
    };

    sops.secrets.registry-builder-password.owner = user;
    sops.secrets.app-deploy-key.owner = user;

    systemd.services.app-builder = {
      description = "Build and deploy the app catalog's new commits";
      wants = [ "network-online.target" docker.userUnit ];
      after = [ "network-online.target" docker.userUnit ];
      path = [ pkgs.git pkgs.git-lfs pkgs.openssh config.virtualisation.docker.package ];
      environment = {
        DOCKER_HOST = docker.dockerHost;
        # the home is read-only under ProtectSystem=strict; docker login writes here
        DOCKER_CONFIG = "${stateDir}/docker";
        APP_DEPLOY_KEY = config.sops.secrets.app-deploy-key.path;
      };
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        Slice = docker.slice;
        StateDirectory = "app-builder";
        WorkingDirectory = stateDir;
        ExecStartPre = login;
        ExecStart = builder;
        # node-exporter's textfile dir belongs to root
        ExecStopPost = "+${pkgs.coreutils}/bin/install -m 0644 ${stateDir}/metrics.prom ${textfile}";
        TimeoutStartSec = "3h";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        PrivateTmp = true;
        # the rootless socket lives under /run/user
        ProtectHome = "read-only";
      };
    };

    systemd.timers.app-builder = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "3min"; OnUnitInactiveSec = pollInterval; };
    };
  };
}
