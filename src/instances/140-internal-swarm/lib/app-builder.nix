# the app catalog's builder: a new commit on an app's branch is built here, parked in the registry and deployed
#
# Runs as `appbuild` against its own rootless docker (modules/rootless-docker.nix), apart from every ci user: only
# this user holds the registry's `builder` credential and the key to the guest swarms' forced command, and it
# builds only the branches the catalog names. It looks at every app every half hour (`git ls-remote` per app, one
# request each); an app's ci asks for a look now through the controller's /redeploy (modules/swarm). A build is
# rolled out start-first with rollback (modules/swarm/lib/swarm-render.py); a failed commit is retried with backoff.
# Deploys to the swarm this host manages go through swarm-deploy@<app>, the one unit polkit lets this user start,
# with the stack in its inbox; guest swarms through their manager's forced command. lib/app-builder.py holds
# the logic; everything it needs is the json below.
#
#   systemctl start app-builder              look at every app now
#   app-builder-redeploy <app>               rebuild and deploy one app now, whatever its state
#   journalctl -u app-builder -u 'app-builder@*'
{ config, lib, pkgs, catalog, inventory, lab, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  user = "appbuild";
  uid = 2001;
  docker = config.homelab.rootlessDocker.${user};
  stateDir = "/var/lib/app-builder";
  # a push is live within this, plus its build, unless its ci asks for a redeploy
  pollInterval = "30min";
  bootDelay = "3min";
  textfile = "/var/lib/node-exporter-textfile/app_builder.prom";
  github = "https://github.com";
  githubApi = "https://api.github.com";
  # its own registry user: a ci job that reads ci's push secret cannot push as the builder
  registryUser = "builder";

  # every network operation is bounded, so one stalled connection fails one app instead of freezing all of them
  timeouts = rec {
    # ls-remote, fetch, submodules, lfs: each of them
    gitS = 5 * 60;
    apiS = 30;
    loginS = 60;
    # a cold rust or node build with --pull
    buildS = 2 * 60 * 60;
    pushS = 30 * 60;
    # the manager's own bound plus the ssh handshake and the stack upload
    deployS = config.homelab.swarm.deployTimeoutS + 5 * 60;
    sshConnectS = 10;
    # a manager gone silent mid-deploy is noticed after interval x count
    sshAliveIntervalS = 15;
    sshAliveCountMax = 4;
  };
  # git: ls-remote, init, fetch, checkout, submodules, lfs install, lfs pull, log
  gitCallsPerApp = 8;
  # reading the catalog and the states, writing the metrics
  runOverheadS = 60;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  cfg = config.homelab.appBuilder;
  guestManagers = lib.unique (lib.concatMap (a: lib.optional (managerOf a != null) (managerOf a).address) (lib.attrValues catalog.apps));
  # the stacks this user hands to swarm-deploy@<app> on this host
  inbox = "${stateDir}/inbox";
  dashboardsImport = pkgs.writers.writePython3 "dashboards-import" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./dashboards-import.py);
  # the cluster this host manages takes its stacks here; any other's (a guest's own swarm) over its forced command
  managerOf = a: if a.cluster.manager == toString config.homelab.appsCatalog.builder then null
    else { address = inventory.${a.cluster.manager}.ip; knownHosts = "${cfg.knownHosts}"; };

  # what decides the images: a change here rebuilds the newest commit even when the branch stood still
  buildInputsOf = a: { inherit (a) repo branch stack build exclude watch; };
  catalogJson = pkgs.writeText "app-builder.json" (builtins.toJSON {
    inherit (catalog) registry;
    inherit registryUser github githubApi timeouts;
    inherit (cfg) backoff;
    registryPasswordFile = config.sops.secrets.registry-builder-password.path;
    deployKeyFile = config.sops.secrets.app-deploy-key.path;
    inherit inbox;
    deployUnit = config.homelab.swarm.deployUnit;
    # one build per core: a rust build uses them all for a while, a small service is mostly waiting on the registry
    buildParallelism = lab.instances.${toString config.homelab.appsCatalog.builder}.config.vm.cores;
    dashboardsImport = "${dashboardsImport}";
    dashboardsDir = config.homelab.swarm.appDashboardsDir;
    apps = lib.mapAttrs (_: a: buildInputsOf a // {
      build = lib.mapAttrs (_: b: { inherit (b) context dockerfile target args; }) a.build;
      hash = builtins.hashString "sha256" (builtins.toJSON (buildInputsOf a));
      manager = managerOf a;
      inherit (a) dashboards;
    }) catalog.apps;
  });

  # the longest one app may take: every git call, every watched path, every image, the deploy
  appTimeoutS = a: gitCallsPerApp * timeouts.gitS + lib.length a.watch * timeouts.apiS + timeouts.loginS
    + lib.length (lib.attrNames a.build) * (timeouts.buildS + 2 * timeouts.pushS) + timeouts.deployS;
  appTimeouts = map appTimeoutS (lib.attrValues catalog.apps);
  runTimeoutS = lib.foldl' (sum: t: sum + t) runOverheadS appTimeouts;

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  builder = pkgs.writeShellScript "app-builder" ''
    exec ${python}/bin/python3 ${./app-builder.py} ${catalogJson} ${stateDir} "$@"
  '';

  serviceConfig = {
    Type = "oneshot";
    User = user;
    Group = user;
    Slice = docker.slice;
    StateDirectory = "app-builder";
    WorkingDirectory = stateDir;
    # "+": the textfile dir is root's; "-": a run that died before its first write left no metrics
    ExecStopPost = "-+${pkgs.coreutils}/bin/install -m 0644 ${stateDir}/metrics.prom ${textfile}";
    # the boards apps ship go to the nas share vm-105 provisions; "+": made as root, then this user's
    ExecStartPre = "+${pkgs.coreutils}/bin/install -d -m 0755 -o ${user} -g ${user} ${config.homelab.swarm.appDashboardsDir}";
    # the share's mount, which exists before the folder: systemd refuses to start a unit naming a missing path
    ReadWritePaths = [ (dirOf config.homelab.swarm.appDashboardsDir) ];
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    PrivateTmp = true;
    # the rootless socket lives under /run/user
    ProtectHome = "read-only";
  };
  unit = {
    unitConfig.RequiresMountsFor = [ config.homelab.swarm.appDashboardsDir ];
    wants = [ "network-online.target" docker.userUnit ];
    after = [ "network-online.target" docker.userUnit ];
    path = [ pkgs.git pkgs.git-lfs pkgs.openssh config.virtualisation.docker.package ];
    environment = {
      DOCKER_HOST = docker.dockerHost;
      # the home is read-only under ProtectSystem=strict; docker login writes here
      DOCKER_CONFIG = "${stateDir}/docker";
    };
  };
in {
  options.homelab.appBuilder.knownHosts = lib.mkOption {
    type = lib.types.path;
    default = ../../../generated/known_hosts;
    defaultText = lib.literalExpression "src/generated/known_hosts";
    description = ''
      The ssh host keys the builder checks the manager against, strictly: no trust on first use. src/generated/known_hosts
      holds every lab host's key, written by sync.sh from the guest itself; a reinstalled manager is trusted again
      after the next sync.
    '';
  };

  options.homelab.appBuilder.backoff = {
    baseS = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = "Wait after a commit's first failed build or deploy; it doubles with every further failure.";
    };
    maxS = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6 * 60 * 60;
      description = "The longest wait between two attempts at the same failing commit; a new commit is tried at once.";
    };
  };

  config = {
    assertions = [{
      assertion = config.networking.hostName == "vm-${toString config.homelab.appsCatalog.builder}";
      message = "the app builder runs on vm-${toString config.homelab.appsCatalog.builder} (src/apps/swarm.nix `builder`), the address the manager's forced command accepts";
    }];

    homelab.rootlessDocker.${user} = {
      inherit uid;
      # rust nightly and node builds; the ci users cap their own share
      memoryMax = "3G";
      buildCacheKeep = "20GB";
      # the registry through the internal ingress, and the guest swarms' forced command; nothing else inside
      labAccess = [ { ip = catalog.ingress.internal.ip; port = 443; } ] ++ map (ip: { inherit ip; port = 22; }) guestManagers;
    };
    # lab names without cloudflare: the ingress terminates https and gates pushes
    networking.hosts.${catalog.ingress.internal.ip} = [ catalog.registry ];

    # its stacks for this host's swarm, which swarm-deploy@<app> reads as root
    systemd.tmpfiles.rules = [ "d ${inbox} 0750 ${user} ${user} -" ];
    homelab.swarm.deployInbox = inbox;
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${user}"
            && action.lookup("verb") == "start" && /^swarm-deploy@[a-z][a-z0-9-]*\.service$/.test(action.lookup("unit"))) {
          return polkit.Result.YES;
        }
      });
    '';

    sops.secrets.registry-builder-password.owner = user;
    sops.secrets.app-deploy-key.owner = user;

    systemd.services.app-builder = unit // {
      description = "Build and deploy the app catalog's new commits";
      serviceConfig = serviceConfig // {
        ExecStart = builder;
        TimeoutStartSec = runTimeoutS;
      };
    };
    # `app-builder-redeploy <app>`: the app, now, whatever its state; waits for a running look at every app
    systemd.services."app-builder@" = unit // {
      description = "Rebuild and redeploy the app %i";
      serviceConfig = serviceConfig // {
        ExecStart = "${builder} %i";
        # it may wait for a whole run to release the lock first
        TimeoutStartSec = runTimeoutS + lib.foldl' lib.max 0 appTimeouts;
      };
    };
    environment.systemPackages = [ (pkgs.writeShellScriptBin "app-builder-redeploy" ''
      exec ${config.systemd.package}/bin/systemctl start "app-builder@''${1:?usage: app-builder-redeploy <app>}.service"
    '') ];

    systemd.timers.app-builder = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = bootDelay; OnUnitInactiveSec = pollInterval; };
    };
  };
}
