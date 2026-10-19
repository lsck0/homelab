# the app catalog's schema: what an app's instances/custom/<name>/app.nix (and instances/core/swarm.nix) may say
#
# modules/lab evaluates it: `lab.appsCatalog` is the typed result, `lab.catalog` (modules/catalog.nix) the lab-wide view
# and its `problems`. Routes, cards and telemetry share modules/service.nix with the instances. The smallest app.nix,
# a function of { lib, profiles }:
#   { ... }: { enable = true; repo = "lsck0/demo"; branch = "master"; routes.demo = { targetPort = 8000; port = 20130; }; }
{
  config,
  lib,
  telemetry,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config;

  # scripts/secrets-sync.nu knows these generators
  secretGenerator = types.strMatching "(guardsData:)?(hex:[1-9][0-9]*|garage-key-id|manual)";
  digestPinned = types.strMatching ".+@sha256:[0-9a-f]{64}";
  secretName = types.strMatching "[a-z0-9][a-z0-9-]*";
  # a path inside the app's checkout: relative, never climbing out (the builder checks the resolved path too)
  repoPath = types.strMatching "([^/.][^/]*|\\.[^/.][^/]*)(/([^/.][^/]*|\\.[^/.][^/]*))*|\\.";

  # one task's share of a worker unless the app asks for more, and the most it may ask (modules/limits: never more than a worker has)
  taskDefaults = {
    memoryMiB = 512;
    cpus = 1.0;
    pids = 512;
  };
  taskMax = {
    memoryMiB = 2048;
    cpus = 2.0;
    pids = 4096;
  };

  # with scaleToZero: a quarter hour covers a reading session's pauses, so a user waits on a cold start once per
  # visit, not per page; shorter only adds wakes, longer only holds memory
  stopAfterDefault = "15m";
  # an app's card is the app's own (platformFeatures), its routes have none
  routeFeatures = lib.remove "homepage" service.protectionFeatures ++ service.exemptionFeatures;

  service = import ../service.nix { inherit lib; };
  inherit (service) serviceName;

  metricsType = types.submodule {
    options = service.swarmBackend // {
      port = mkOption {
        type = types.port;
        description = "Published on every node, unique across apps; scraped, never routed.";
      };
      path = mkOption {
        type = types.str;
        description = "The prometheus scrape path.";
      };
    };
  };

  # a route's published port unless it names one: stable per route name, anywhere in the range; a clash is a
  # catalog problem naming both routes
  portHashDigits = 6;
  portOfRoute =
    name:
    let
      range = cfg.swarm.portRange;
    in
    range.first
    + lib.mod (lib.fromHexString (lib.substring 0 portHashDigits (builtins.hashString "sha256" name))) (
      range.last - range.first + 1
    );

  routeType =
    app:
    types.submodule (
      { name, config, ... }:
      {
        options = service.exposureOptions {
          name = app;
          zone = "external";
          features = routeFeatures;
          backend = service.swarmBackend;
        };
        config = {
          port = lib.mkDefault (portOfRoute name);
          # an app's root answers its health check by default; another prefix only names one that answers
          health = lib.mkDefault (if config.path == "/" then "/" else null);
        };
      }
    );

  buildType = types.submodule (
    { config, ... }:
    {
      options = {
        context = mkOption {
          type = repoPath;
          default = ".";
          description = "Build context, relative to the repo root.";
        };
        dockerfile = mkOption {
          type = repoPath;
          default = if config.context == "." then "Dockerfile" else "${config.context}/Dockerfile";
          defaultText = lib.literalExpression ''"<context>/Dockerfile"'';
          description = "The Dockerfile, relative to the repo root.";
        };
        target = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Multi-stage build target; null: the last stage.";
        };
        args = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Build arguments.";
        };
      };
    }
  );

  # a site built by a command, served by the platform's static server (107-internal-swarm/lib/static-site.nix)
  staticType = types.submodule {
    options = {
      command = mkOption {
        type = types.str;
        description = "Builds the site at the repo root, with no network, as `sh -c`.";
      };
      output = mkOption {
        type = repoPath;
        description = "The directory the command leaves the site in, relative to the repo root.";
      };
      packages = mkOption {
        type = types.functionTo (types.listOf types.package);
        default = _: [ ];
        defaultText = lib.literalExpression "pkgs: [ ]";
        description = "pkgs -> what the command runs with, its PATH and /usr/bin; a shell and coreutils always.";
      };
    };
  };

  dumpType = types.submodule {
    options = {
      service = mkOption {
        type = serviceName;
        description = "A stateful service; the command runs in its container.";
      };
      command = mkOption {
        type = types.str;
        description = "Writes a consistent dump to stdout (`pg_dumpall -U admin`).";
      };
      restore = mkOption {
        type = types.str;
        description = "A shell command in the service's container reading a dump of `command` on stdin (`psql -U admin -d postgres`): swarm-dump-restore.";
      };
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
  resourcesType =
    defaults:
    types.submodule {
      options = {
        memoryMiB = mkOption {
          type = types.ints.positive;
          default = defaults.memoryMiB;
          description = "Memory limit of each task.";
        };
        cpus = mkOption {
          type = types.number;
          default = defaults.cpus;
          description = "CPU limit of each task, in cores.";
        };
        pids = mkOption {
          type = types.ints.positive;
          default = defaults.pids;
          description = "Process and thread limit of each task.";
        };
      };
    };

  appType = types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "false: not built, deployed, routed, scraped or alerted on; a running stack is removed.";
        };
        repo = mkOption {
          type = types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
          description = "The GitHub repo, owner/name.";
        };
        branch = mkOption {
          type = types.strMatching "[^ ]+";
          description = "The branch deployed.";
        };
        stack = mkOption {
          type = types.nullOr repoPath;
          default = null;
          description = ''
            The compose file in the repo; null: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml
            or stack.yaml at the root, else one service "web" built from the root Dockerfile.
          '';
        };
        build = mkOption {
          type = types.attrsOf buildType;
          default = { };
          description = "Service -> build, for stack services that only name an image.";
        };
        static = mkOption {
          type = types.nullOr staticType;
          default = null;
          description = "A static site instead of a stack: one service \"web\", the platform's server with the built site, no Dockerfile.";
        };
        requireChecks = mkOption {
          type = types.bool;
          default = false;
          description = "Deploy a commit only once every GitHub check run on it succeeded: one still running waits for the next look, one failed is the commit's failure.";
        };
        schedule = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "A systemd calendar the builder looks at the app on, instead of every poll: for a build too heavy for every push.";
        };
        watch = mkOption {
          type = types.listOf repoPath;
          default = [ ];
          description = "Repo paths: deploy only commits that touch them, for an app inside a busier repo; empty: every commit.";
        };
        routes = mkOption {
          type = types.attrsOf (routeType name);
          # the app at <app>.<domain> on the edge, a plain route
          default.${name} = { };
          description = "Route name (unique in the lab) -> a host and prefix on the internal ingress or the edge, served by a stack service.";
        };
        exclude = mkOption {
          type = types.listOf serviceName;
          default = [ ];
          description = "Stack services the homelab replaces (monitoring, edge proxies): dropped with every dependency on them.";
        };
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
        dumps = mkOption {
          type = types.attrsOf dumpType;
          default = { };
          description = "Name -> a dump command, run nightly on the state worker, to the nas.";
        };
        env = mkOption {
          type = types.attrsOf (types.attrsOf types.str);
          default = { };
          description = ''
            Service -> KEY -> value, over the stack's own environment of that service only: a secret reaches the
            services that name it and no other. In a value, `{{name}}` is the sops secret <name> (see `secrets`),
            `{{homelab.otlp-grpc}}`, `{{homelab.otlp-http}}` and `{{homelab.pyroscope}}` (host:port) are the lab's
            telemetry endpoints (they need `telemetry`), `{{homelab.origin-<route>}}` is a route's https origin, and
            `{{.Node.Hostname}}`-style templates are swarm's.
          '';
        };
        secretFiles = mkOption {
          type = types.attrsOf (types.attrsOf secretName);
          default = { };
          description = ''
            Service -> KEY -> a secret of `secrets`, mounted at /run/secrets/<KEY> with <KEY>_FILE naming it, for images
            that read a _FILE variable: unlike an `env` value, it is in no service spec, `docker inspect` or process
            environment.
          '';
        };
        secrets = mkOption {
          type = types.attrsOf secretGenerator;
          default = { };
          description = ''
            Sops secret name -> its generator for scripts/secrets-sync.nu: "hex:<bytes>" or "garage-key-id", prefixed
            "guardsData:" when data or logins depend on it, or "manual" for a third party's (an api key, smtp), set
            with sops; the app does not deploy while one is empty. Exactly the secrets `env` and `secretFiles` name.
          '';
        };
        resources = mkOption {
          type = types.attrsOf (resourcesType cfg.swarm.taskDefaults);
          default = { };
          description = "Service -> its tasks' limits, at most `swarm.taskMax`; unlisted services get `swarm.taskDefaults`. The stack's own limits are replaced.";
        };
        reservation = {
          memoryMiB = mkOption {
            type = types.ints.positive;
            default = cfg.swarm.taskDefaults.memoryMiB;
            defaultText = "swarm.taskDefaults.memoryMiB: one task";
            description = "Memory the app's tasks hold together, replicas counted.";
          };
          cpus = mkOption {
            type = types.number;
            default = 0.5;
            description = "Cores the app's tasks reserve together, 0.1 per task.";
          };
        };
        override = mkOption {
          type = types.attrs;
          default = { };
          description = "A compose overlay merged last, as nix attrs; the policy still applies to the result.";
        };
        images = mkOption {
          type = types.listOf digestPinned;
          default = [ ];
          description = "Public images the stack may run besides its own builds, each pinned by digest.";
        };
        metrics = mkOption {
          type = types.attrsOf metricsType;
          default = { };
          description = "Name -> an exporter scraped every 15s by vm-103, never routed.";
        };
        alerts = mkOption {
          type = types.attrsOf telemetry.alertType;
          default = { };
          description = "Name -> a rule over the app's own metrics or logs (modules/telemetry.nix alertType); its Grafana uid is app_<app>_<name>.";
        };
        homepage = mkOption {
          type = service.cardType {
            inherit name;
            group = "Swarm";
            icon = "mdi-docker";
            description = "${config.repo}@${config.branch}";
          };
          default = { };
          description = "The app's card on the dashboard (vm-102), shown with the homepage feature.";
        };
        on = mkOption {
          type = service.featuresType (service.telemetryFeatures ++ service.platformFeatures);
          default = [ ];
          description = "The telemetry and platform features opted into (modules/profiles.nix); scaleToZero: the stack sleeps after `idle.stopAfter` without requests.";
        };
        dashboards = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Globs in the repo (`grafana/*.json`): Grafana boards of the deployed commit, in the app's folder beside its
            generated board, every datasource the app's own (instances/core/107-internal-swarm/lib/dashboards-import.py); one that does not parse
            fails the deploy.
          '';
        };
        idle = mkOption {
          type = service.idleType;
          default = { };
          description = "When the stack scales to zero on its own (stopAfter ${stopAfterDefault} with scaleToZero); the ingress wakes it.";
        };
        placement = mkOption {
          type = types.nullOr (
            types.submodule {
              options = {
                zone = mkOption {
                  type = types.enum [
                    "internal"
                    "external"
                  ];
                  description = "The zone of the app's own guest.";
                };
                vmid = mkOption {
                  type = types.ints.positive;
                  description = "The guest's vmid, inside the zone's range.";
                };
                vm = mkOption {
                  type = types.attrs;
                  default = { };
                  description = "The guest's vm shape (modules/instance-schema.nix `vm`).";
                };
              };
            }
          );
          default = null;
          description = "null: the shared apps swarm; else the app's own guest, a single-node swarm.";
        };
      };
      config.idle.stopAfter = lib.mkDefault (if lib.elem "scaleToZero" config.on then stopAfterDefault else null);
    }
  );
in
{
  options = {
    apps = mkOption {
      type = types.attrsOf appType;
      default = { };
      description = "App name ([a-z][a-z0-9-]*) -> a GitHub repo and a branch, everything else derived.";
    };
    swarm = {
      manager = mkOption {
        type = types.ints.positive;
        description = "Vmid of the swarm manager, a guest of the internal zone.";
      };
      state = mkOption {
        type = types.ints.positive;
        description = "Vmid of the worker holding every stateful service's volumes; moving it moves no data.";
      };
      workers = mkOption {
        type = types.listOf types.ints.positive;
        description = "Vmids of the shared swarm's workers (instances/core/swarm.nix `nodes`); an app's own guest is not one.";
      };
      portRange = {
        first = mkOption {
          type = types.port;
          default = 20100;
          description = "First port an app may publish.";
        };
        last = mkOption {
          type = types.port;
          default = 20999;
          description = "Last port an app may publish.";
        };
      };
      taskDefaults = mkOption {
        type = resourcesType taskDefaults;
        default = { };
        description = "Limits of a task whose service `resources` does not list.";
      };
      taskMax = mkOption {
        type = resourcesType taskMax;
        default = { };
        description = "The most an app's `resources` may grant one task.";
      };
    };
    builder = mkOption {
      type = types.ints.positive;
      description = "Vmid of the guest that builds and deploys the apps (107-internal-swarm/lib/app-builder.nix); the manager's forced command accepts its address only.";
    };
    cadvisorPort = mkOption {
      type = types.port;
      description = "Per-worker container metrics, scraped on every worker; outside the app range.";
    };
    controllerPort = mkOption {
      type = types.port;
      description = "The managers' controller (redeploys, an idle app's wake and sleep).";
    };
  };
}
