# the app catalog's schema: what an app's src/apps/<name>/app.nix (and src/apps/swarm.nix) may say, typed once
#
# modules/lab evaluates this module over the app folders and src/apps/swarm.nix: `lab.appsCatalog` is the typed
# result, `lab.catalog` (modules/catalog.nix) the lab-wide view over it that every host gets as the argument
# `catalog`. Routes, cards and telemetry share modules/service.nix with the instances. Lab-wide rules (unique
# routes, hosts and ports, every secret reference generated) are modules/catalog.nix's `problems`, which stop the
# flake's evaluation. A test with a fixture app hands its hosts another catalog:
#
#   lab.withApps (apps: lib.recursiveUpdate apps { wat.enable = true; })    (tests/lib/lab.nix `apps`)
#
# The smallest app, src/apps/demo/app.nix, serves one public path:
#
#   {
#     enable = true;
#     repo = "lsck0/demo";
#     branch = "master";
#     routes.demo = { service = "web"; targetPort = 8000; port = 20130; off.sso = "public"; };
#   }
{ config, lib, telemetry, ... }:
let
  inherit (lib) mkOption types;
  cfg = config;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # scripts/secrets-sync.sh knows these generators
  secretGenerator = types.strMatching "hex:[1-9][0-9]*|garage-key-id";
  digestPinned = types.strMatching ".+@sha256:[0-9a-f]{64}";
  # a path inside the app's checkout: relative, never climbing out (the builder checks the resolved path too)
  repoPath = types.strMatching "([^/.][^/]*|\\.[^/.][^/]*)(/([^/.][^/]*|\\.[^/.][^/]*))*|\\.";

  # one task's share of a worker unless the app asks for more, and the most it may ask (limits.nix: never more than a worker has)
  taskDefaults = { memoryMiB = 512; cpus = 1.0; pids = 512; };
  taskMax = { memoryMiB = 2048; cpus = 2.0; pids = 4096; };

  # -----------------------------------------------------------------------------
  # TYPES
  # -----------------------------------------------------------------------------

  service = import ../service.nix { inherit lib; };
  inherit (service) serviceName;

  metricsType = types.submodule {
    options = service.swarmBackend // {
      port = mkOption { type = types.port; description = "Published on every node, unique across apps; scraped, never routed."; };
      path = mkOption { type = types.str; description = "The prometheus scrape path."; };
    };
  };

  # a route's published port unless it names one: stable per route name, anywhere in the range; a clash is a
  # catalog problem naming both routes
  portHashDigits = 6;
  portOfRoute = name: let range = cfg.swarm.portRange; in
    range.first + lib.mod (lib.fromHexString (lib.substring 0 portHashDigits (builtins.hashString "sha256" name)))
      (range.last - range.first + 1);

  routeType = app: types.submodule ({ name, config, ... }: {
    options = service.exposureOptions { name = app; zone = "external"; features = service.protectionFeatures; backend = service.swarmBackend; };
    config = {
      port = lib.mkDefault (portOfRoute name);
      # an app's root answers its health check by default; another prefix only names one that answers
      health = lib.mkDefault (if config.path == "/" then "/" else null);
    };
  });

  buildType = types.submodule ({ config, ... }: {
    options = {
      context = mkOption { type = repoPath; default = "."; description = "Build context, relative to the repo root."; };
      dockerfile = mkOption {
        type = repoPath;
        default = if config.context == "." then "Dockerfile" else "${config.context}/Dockerfile";
        defaultText = lib.literalExpression ''"<context>/Dockerfile"'';
        description = "The Dockerfile, relative to the repo root.";
      };
      target = mkOption { type = types.nullOr types.str; default = null; description = "Multi-stage build target; null: the last stage."; };
      args = mkOption { type = types.attrsOf types.str; default = { }; description = "Build arguments."; };
    };
  });

  dumpType = types.submodule {
    options = {
      service = mkOption { type = serviceName; description = "A stateful service; the command runs in its container."; };
      command = mkOption { type = types.str; description = "Writes a consistent dump to stdout (`pg_dumpall -U admin`)."; };
    };
  };

  volumeType = types.submodule {
    options.backup = mkOption {
      type = types.bool;
      description = ''
        Archive the volume nightly from the state worker to the nas, its containers paused for the copy
        (crash-consistent). No default: every volume of a stack states it, so leaving one out is a decision,
        visible here. false where a dump already covers it (a database) or it is a cache.
      '';
    };
  };

  # pids bound a fork bomb; a node process or a jvm needs a few hundred threads
  resourcesType = defaults: types.submodule {
    options = {
      memoryMiB = mkOption { type = types.ints.positive; default = defaults.memoryMiB; description = "Memory limit of each task."; };
      cpus = mkOption { type = types.number; default = defaults.cpus; description = "CPU limit of each task, in cores."; };
      pids = mkOption { type = types.ints.positive; default = defaults.pids; description = "Process and thread limit of each task."; };
    };
  };

  appType = types.submodule ({ name, config, ... }: {
    options = {
      enable = mkOption { type = types.bool; default = false; description = "false: not built, deployed, routed, scraped or alerted on; a running stack is removed."; };
      repo = mkOption { type = types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"; description = "The GitHub repo, owner/name."; };
      branch = mkOption { type = types.strMatching "[^ ]+"; description = "The branch deployed."; };
      stack = mkOption {
        type = types.nullOr repoPath;
        default = null;
        description = ''
          The compose file in the repo; null: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml
          or stack.yaml at the root, else one service "web" built from the root Dockerfile.
        '';
      };
      build = mkOption { type = types.attrsOf buildType; default = { }; description = "Service -> build, for stack services that only name an image."; };
      watch = mkOption {
        type = types.listOf repoPath;
        default = [ ];
        description = "Repo paths: deploy only commits that touch them, for an app inside a busier repo; empty: every commit.";
      };
      routes = mkOption {
        type = types.attrsOf (routeType name);
        # the app at <app>.<domain>, behind the edge and authelia
        default.${name} = { };
        description = "Route name (unique in the lab) -> a host and prefix on the internal ingress or the edge, served by a stack service.";
      };
      exclude = mkOption { type = types.listOf serviceName; default = [ ]; description = "Stack services the homelab replaces (monitoring, edge proxies): dropped with every dependency on them."; };
      stateful = mkOption {
        type = types.listOf serviceName;
        default = [ ];
        description = "Services with volumes: pinned to the state worker (`swarm.state`), one task, stopped before replaced.";
      };
      volumes = mkOption {
        type = types.attrsOf volumeType;
        default = { };
        description = "Every named volume of the stack, by its name there, and whether the state worker archives it.";
      };
      dumps = mkOption { type = types.attrsOf dumpType; default = { }; description = "Name -> a dump command, run nightly on the state worker, to the nas."; };
      env = mkOption {
        type = types.attrsOf (types.attrsOf types.str);
        default = { };
        description = ''
          Service -> KEY -> value, over the stack's own environment of that service only: a secret reaches the
          services that name it and no other. In a value, `{{name}}` is the sops secret <name> (see `secrets`),
          `{{homelab.otlp-grpc}}`, `{{homelab.otlp-http}}` and `{{homelab.pyroscope}}` (host:port) are the lab's
          telemetry endpoints (they need `telemetry`), and `{{.Node.Hostname}}`-style templates are swarm's.
        '';
      };
      secrets = mkOption {
        type = types.attrsOf secretGenerator;
        default = { };
        description = ''
          Sops secret name -> its generator for scripts/secrets-sync.sh: "hex:<bytes>" or "garage-key-id".
          Exactly the secrets `env` names.
        '';
      };
      resources = mkOption {
        type = types.attrsOf (resourcesType cfg.swarm.taskDefaults);
        default = { };
        description = "Service -> its tasks' limits, at most `swarm.taskMax`; unlisted services get `swarm.taskDefaults`. The stack's own limits are replaced.";
      };
      reservation = {
        memoryMiB = mkOption { type = types.ints.positive; default = 1024; description = "Memory the app's tasks hold together, replicas counted."; };
        cpus = mkOption { type = types.number; default = 0.5; description = "Cores the app's tasks reserve together, 0.1 per task."; };
      };
      override = mkOption { type = types.attrs; default = { }; description = "A compose overlay merged last, as nix attrs; the policy still applies to the result."; };
      images = mkOption { type = types.listOf digestPinned; default = [ ]; description = "Public images the stack may run besides its own builds, each pinned by digest."; };
      metrics = mkOption { type = types.attrsOf metricsType; default = { }; description = "Name -> an exporter scraped every 15s by vm-105, never routed."; };
      alerts = mkOption {
        type = types.attrsOf telemetry.alertType;
        default = { };
        description = "Name -> a rule over the app's own metrics or logs (modules/telemetry.nix alertType); its Grafana uid is app_<app>_<name>.";
      };
      homepage = mkOption {
        type = service.cardType { inherit name; group = "Swarm"; icon = "mdi-docker"; description = "${config.repo}@${config.branch}"; };
        default = { };
        description = "The app's card on the dashboard (vm-103).";
      };
      off = mkOption { type = service.offType service.telemetryFeatures; default = { }; description = "Telemetry feature -> why it is off."; };
      dashboards = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Globs in the repo (`grafana/*.json`): Grafana boards of the deployed commit, in the app's folder beside its
          generated board, every datasource the app's own (instances/140-internal-swarm/lib/dashboards-import.py); one that does not parse
          fails the deploy.
        '';
      };
      idle = mkOption { type = service.idleType; default = { }; description = "When the stack stops on its own; the ingress wakes it."; };
      placement = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            zone = mkOption { type = types.enum [ "internal" "external" ]; description = "The zone of the app's own guest."; };
            vmid = mkOption { type = types.ints.positive; description = "The guest's vmid, inside the zone's range."; };
            vm = mkOption { type = types.attrs; default = { }; description = "The guest's vm shape (modules/instance-schema.nix `vm`)."; };
          };
        });
        default = null;
        description = "null: the shared apps swarm; else the app's own guest, a single-node swarm.";
      };
    };
  });
in {
  options = {
    apps = mkOption {
      type = types.attrsOf appType;
      default = { };
      description = "App name ([a-z][a-z0-9-]*) -> a GitHub repo and a branch, everything else derived.";
    };
    swarm = {
      manager = mkOption { type = types.ints.positive; description = "Vmid of the swarm manager, a guest of the internal zone."; };
      state = mkOption { type = types.ints.positive; description = "Vmid of the worker holding every stateful service's volumes; moving it moves no data."; };
      workers = mkOption { type = types.listOf types.ints.positive; description = "Vmids of the shared swarm's workers (apps/swarm.nix `nodes`); an app's own guest is not one."; };
      portRange = {
        first = mkOption { type = types.port; default = 20100; description = "First port an app may publish."; };
        last = mkOption { type = types.port; default = 20999; description = "Last port an app may publish."; };
      };
      taskDefaults = mkOption { type = resourcesType taskDefaults; default = { }; description = "Limits of a task whose service `resources` does not list."; };
      taskMax = mkOption { type = resourcesType taskMax; default = { }; description = "The most an app's `resources` may grant one task."; };
    };
    builder = mkOption {
      type = types.ints.positive;
      description = "Vmid of the guest that builds and deploys the apps (140-internal-swarm/lib/app-builder.nix); the manager's forced command accepts its address only.";
    };
    cadvisorPort = mkOption { type = types.port; description = "Per-worker container metrics, scraped on every worker; outside the app range."; };
    controllerPort = mkOption { type = types.port; description = "The managers' controller (redeploys, an idle app's wake and sleep)."; };
  };
}
