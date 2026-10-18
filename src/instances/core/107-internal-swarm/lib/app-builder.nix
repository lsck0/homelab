# the app catalog's builder: a new commit on an app's branch is built here, parked in the registry and deployed
#
# security: runs as `appbuild` on its own rootless docker, apart from every ci user: only it holds the registry's
# `builder` credential and the key to the guest swarms' forced command, and it builds only the branches the catalog
# names. Its one privileged act is swarm-deploy@<app>, the unit polkit lets it start.
#
#   systemctl start app-builder              look at every app now
#   systemctl start app-builder@<app>        look at one app now, what its ci's /redeploy does
#   app-builder-redeploy <app>               forget the app's state, then deploy it again whatever it was
#   journalctl -u app-builder -u 'app-builder@*'
{ config, lib, pkgs, catalog, inventory, lab, upstream, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  user = "appbuild";
  uid = 2001;
  builderId = lab.roles.app-builder;
  docker = config.homelab.rootlessDocker.${user};
  stateDir = "/var/lib/app-builder";
  # a push is live within this, plus its build, unless its ci asks for a redeploy
  pollInterval = "30min";
  # a deploy this old is looked at again for its base images (a security fix in debian or alpine) without a commit
  baseRefreshS = 24 * 60 * 60;
  textfileName = "app_builder";
  textfile = "${config.homelab.textfileDir}/${textfileName}.prom";
  vm = lab.instances.${builderId}.config.vm;
  # the balloon floor holds the manager (instance.nix); builds get the rest when the host has it free
  memoryMaxMiB = vm.memoryMiB - vm.balloonMiB;
  # the peak of one cold rust or node build: builds run side by side only as far as both cores and memory hold
  buildMemoryMiB = 1024;
  github = "https://github.com";
  githubApi = "https://api.github.com";
  # a ci job that reads ci's push secret cannot push as the builder
  registryUser = "builder";

  # every network operation is bounded, so one stalled connection fails one app instead of freezing all of them
  timeouts = rec {
    # each of ls-remote, fetch, submodules, lfs
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
  runOverheadS = 60;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  cfg = config.homelab.appBuilder;
  guestManagers = lib.unique (lib.concatMap (a: lib.optional (managerOf a != null) (managerOf a).address) (lib.attrValues catalog.apps));
  inbox = "${stateDir}/inbox";
  dashboardsImport = pkgs.writers.writePython3 "dashboards-import" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./dashboards-import.py);
  # the cluster this host manages takes its stacks here; any other's (a guest's own swarm) over its forced command
  managerOf = a: if a.cluster.manager == builderId then null
    else { address = inventory.${a.cluster.manager}.ip; knownHosts = "${cfg.knownHosts}"; };

  staticSite = import ./static-site.nix { inherit pkgs lib; };
  indexableOrigins = a: map (r: "https://${r.host}.${catalog.domain}") (lib.filter (r: r.indexable) (lib.attrValues a.routes));
  # a static app's build as lib/app-builder.py runs it; its store paths decide a deploy, so a new toolchain or server
  # rebuilds. An indexable route's origin gets a robots.txt and a sitemap.xml in the site
  staticOf = name: a: if a.static == null then null else {
    inherit (a.static) command output;
    inherit (staticSite) server build root;
    toolchain = "${staticSite.toolchainOf name a.static.packages}";
    indexable = lib.findFirst (_: true) null (indexableOrigins a);
  };
  staticApps = lib.filterAttrs (_: a: a.static != null) catalog.apps;

  # what decides a deploy: a change here deploys the newest commit again even when the branch stood still
  buildInputsOf = name: a: { inherit (a) repo branch stack build exclude watch dashboards; static = staticOf name a; };
  catalogJson = pkgs.writeText "app-builder.json" (builtins.toJSON {
    inherit (catalog) registry;
    inherit registryUser github githubApi timeouts;
    inherit (cfg) backoff;
    inherit baseRefreshS;
    upstreams = {
      urls = lib.mapAttrs (_: u: u.url) lab.upstreams;
      inherit (upstream) registries retry unavailable;
    };
    registryPasswordFile = config.sops.secrets.registry-builder-password.path;
    deployKeyFile = config.sops.secrets.app-deploy-key.path;
    # read access to the private repos of the catalog; empty: public repos only
    githubTokenFile = config.sops.secrets.github-mirror-token.path;
    workDir = "${stateDir}/work";
    inherit inbox;
    deployUnit = config.homelab.swarm.deployUnit;
    buildParallelism = lib.min vm.cores (memoryMaxMiB / buildMemoryMiB);
    dashboardsImport = "${dashboardsImport}";
    dashboardsDir = config.homelab.swarm.appDashboardsDir;
    apps = lib.mapAttrs (name: a: buildInputsOf name a // {
      build = lib.mapAttrs (_: b: { inherit (b) context dockerfile target args; }) a.build;
      hash = builtins.hashString "sha256" (builtins.toJSON (buildInputsOf name a));
      manager = managerOf a;
      inherit (a) dashboards schedule;
    }) catalog.apps;
  });

  # an upstream call at its worst: every attempt at its bound, the doubling backoffs between them, the probe
  backoffsS = (lib.foldl' (acc: _: { sumS = acc.sumS + acc.delayS; delayS = acc.delayS * 2; })
    { sumS = 0; delayS = upstream.retry.backoffS; } (lib.range 2 upstream.retry.attempts)).sumS;
  retriedS = boundS: upstream.retry.attempts * boundS + backoffsS + upstream.retry.probeTimeoutS;
  # the longest one app may take: every git call, every watched path, every image (its base's pull retried), the deploy
  appTimeoutS = a: retriedS (gitCallsPerApp * timeouts.gitS + lib.length a.watch * timeouts.apiS) + timeouts.loginS
    + lib.length (lib.attrNames a.build ++ lib.optional (a.static != null) "web") * (retriedS timeouts.pushS + timeouts.buildS + 2 * timeouts.pushS) + timeouts.deployS;
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
    # the boards apps ship go to the nas share vm-103 provisions; "+": made as root, then this user's
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
    default = ../../../../generated/known_hosts;
    defaultText = lib.literalExpression "src/generated/known_hosts";
    description = ''
      The ssh host keys the builder checks the manager against, strictly: no trust on first use. src/generated/known_hosts
      holds every lab host's key, written by sync.nu from the guest itself; a reinstalled manager is trusted again
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
    homelab.textfiles = [ textfileName ];

    assertions = lib.mapAttrsToList (name: a: {
      assertion = a.stack == null && a.build == { } && a.stateful == [ ] && lib.length (indexableOrigins a) <= 1;
      message = "app ${name} is static: it names no stack, build or stateful service, and one indexable origin at most";
    }) staticApps ++ [
      {
        assertion = config.homelab.vmid == builderId;
        message = "the app builder runs on vm-${builderId} (the role app-builder), the address the managers' forced command accepts";
      }
      {
        assertion = vm.balloonMiB > 0 && memoryMaxMiB >= buildMemoryMiB;
        message = "vm-${builderId}: memoryMiB ${toString vm.memoryMiB} above its balloon floor ${toString vm.balloonMiB} must hold one build (${toString buildMemoryMiB} MiB)";
      }
    ];

    homelab.rootlessDocker.${user} = {
      inherit uid;
      memoryMax = "${toString memoryMaxMiB}M";
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
    sops.secrets.github-mirror-token.owner = user;

    systemd.services.app-builder = unit // {
      description = "Build and deploy the app catalog's new commits";
      serviceConfig = serviceConfig // {
        ExecStart = builder;
        TimeoutStartSec = runTimeoutS;
      };
    };
    systemd.services."app-builder@" = unit // {
      description = "Look at the app %i now";
      serviceConfig = serviceConfig // {
        ExecStart = "${builder} %i";
        # it may wait for a run already at this app first
        TimeoutStartSec = 2 * lib.foldl' lib.max 0 appTimeouts;
      };
    };
    # a switch that changes the catalog (an app's build settings, dashboards, a new app) is looked at now, as is a boot
    systemd.services.app-builder-catalog = {
      description = "Look at every app when the catalog changes";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ catalogJson ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/bin/systemctl start --no-block app-builder.service";
      };
    };
    environment.systemPackages = [ (pkgs.writeShellApplication {
      name = "app-builder-redeploy";
      runtimeInputs = [ pkgs.util-linux config.systemd.package ];
      text = ''
        app=''${1:?usage: app-builder-redeploy <app>}
        [[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "app-builder-redeploy: '$app' is no app name" >&2; exit 2; }
        # under the app's lock (lib/app-builder.py app_lock), as its owner: a run at it finishes first
        runuser -u ${user} -- flock ${stateDir}/"$app".lock rm -f ${stateDir}/"$app".json
        systemctl start "app-builder@$app.service"
      '';
    }) ];

    systemd.timers = {
      app-builder = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnUnitInactiveSec = pollInterval;
      };
    } // lib.mapAttrs' (name: a: lib.nameValuePair "app-builder-${name}" {
      wantedBy = [ "timers.target" ];
      # a schedule missed while the vm was down runs at its boot
      timerConfig = { OnCalendar = a.schedule; Persistent = true; Unit = "app-builder@${name}.service"; };
    }) (lib.filterAttrs (_: a: a.schedule != null) catalog.apps);
  };
}
