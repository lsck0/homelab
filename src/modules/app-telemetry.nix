# a swarm worker's side of the apps' telemetry: container logs bounded on the node and shipped per app, container
# metrics bounded in cardinality; modules/swarm enables it on every worker
#
# Logs. Docker writes each container's output to its own rotated files (the `local` driver), never to the node's
# journal, and drops lines rather than block a container that writes faster than the disk takes them. A promtail
# reads them over the docker api, one job per enabled app, and lets each app through at the lab's per-service rate
# (modules/limits `tenant`); the rest is dropped here, counted per app, before it costs the network, loki or
# another app anything. In loki each app is its own tenant with the same budget, so no app's lines wait on another's.
# Labels stay the ones the journal pipeline gave app logs (container_name, swarm_service, swarm_stack, host), so a
# query or alert over them reads both.
#
# Metrics. cadvisor reports docker containers only, with no container label turned into a prometheus label: an app's
# own labels would otherwise be series names the scrape of every app pays for. vm-105 derives stack and service
# from the task name (modules/telemetry.nix swarmTaskPatterns).
#
# Rejected: the docker journald driver. Every container logs as docker.service, so journald's per-unit rate limit
# suppressed every app on the node once one flooded, and the upload filled vm-105's journal-remote directory, which
# ignores its size cap between vacuums.
{ config, lib, pkgs, inventory, catalog, ... }:
let
  cfg = config.homelab.appTelemetry;
  telemetry = import ./telemetry.nix { inherit lib inventory; };
  inherit (config.homelab.appsCatalog) cadvisorPort;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # per container on the node: 3 x 10 MB, what `docker service logs` still shows after the shipper read it
  logFileBytes = "10m";
  logFiles = "3";
  # a container writing faster than the driver stores keeps running; above this the newest lines are lost
  logBufferBytes = "4m";
  dockerSocket = "unix:///run/docker.sock";
  # a new task's container is found within this; its lines are read from its start, none are lost
  discoveryInterval = "10s";
  stackLabel = "com.docker.stack.namespace";
  shipperJob = "app-logs";
  positions = "/var/lib/promtail/positions.yaml";
  # cpu, memory, network, disk io, oom kills, and processes for the pids limit; the per-cpu and tcp families stay off
  cadvisorMetrics = [ "cpu" "memory" "network" "diskIO" "oom_event" "process" ];
  # vm-105 scrapes every 15s; the 1s default spent a third of a core on a worker with a dozen tasks
  cadvisorHousekeeping = "10s";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  # the docker api names a container /<stack>_<service>.<slot>.<task id>
  taskLabel = pattern: label: { source_labels = [ "__meta_docker_container_name" ]; regex = "/${pattern}"; target_label = label; };

  budget = (import ./limits { inherit lib; }).tenant;
  appJob = app: {
    job_name = "app-${app}";
    docker_sd_configs = [{
      host = dockerSocket;
      refresh_interval = discoveryInterval;
      filters = [{ name = "label"; values = [ "${stackLabel}=${app}" ]; }];
    }];
    relabel_configs = [
      { target_label = "job"; replacement = shipperJob; }
      { target_label = "host"; replacement = config.networking.hostName; }
      { source_labels = [ "__meta_docker_container_log_stream" ]; target_label = "stream"; }
      (taskLabel telemetry.swarmTaskPatterns.container "container_name")
      (taskLabel telemetry.swarmTaskPatterns.service "swarm_service")
      (taskLabel telemetry.swarmTaskPatterns.stack "swarm_stack")
    ];
    # by_label_name: the drops are counted per app (logentry_dropped_lines_by_label_total), each job holds one
    pipeline_stages = [
      { tenant.value = telemetry.tenantOf app; }
      {
        limit = {
          rate = budget.logLinesPerSecond;
          burst = budget.logBurstLines;
          drop = true;
          by_label_name = "swarm_stack";
        };
      }
    ];
  };
in {
  options.homelab.appTelemetry = {
    enable = lib.mkEnableOption "the swarm worker's per-app log shipping and container metrics";
    shipperJob = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = shipperJob;
      description = "The `job` label of the apps' container logs, and vm-105's scrape job of the shippers.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.daemon.settings = {
      log-driver = "local";
      log-opts = { max-size = logFileBytes; max-file = logFiles; mode = "non-blocking"; max-buffer-size = logBufferBytes; };
    };

    services.promtail = {
      enable = true;
      configuration = {
        server = { http_listen_port = telemetry.ports.promtail; grpc_listen_port = 0; };
        positions.filename = positions;
        # a refused batch (loki restarting, a limit) is dropped and counted, never retried ahead of the next app's
        clients = [{ url = telemetry.urls.lokiPush; drop_rate_limited_batches = true; }];
        # longer lines are cut, not dropped; loki cuts at the same length
        limits_config = { max_line_size = budget.logLineBytes; max_line_size_truncate = true; };
        scrape_configs = map appJob (lib.attrNames catalog.apps);
      };
    };
    systemd.services.promtail = {
      serviceConfig.StateDirectory = "promtail";
      # the docker api's log endpoint; promtail is lab code, the apps' containers cannot reach it
      serviceConfig.SupplementaryGroups = [ "docker" ];
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
    };

    # vm-105 scrapes the shipper for what it dropped per app and cadvisor for the containers (modules/flows.nix)
    networking.firewall.allowedTCPPorts = [ telemetry.ports.promtail cadvisorPort ];
    homelab.ingressOnly.ports = [ telemetry.ports.promtail cadvisorPort ];

    services.cadvisor = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = cadvisorPort;
      extraOptions = [
        "-docker_only"
        "-store_container_labels=false"
        "-enable_metrics=${lib.concatStringsSep "," cadvisorMetrics}"
        "-housekeeping_interval=${cadvisorHousekeeping}"
      ];
    };
  };
}
