# a swarm worker's side of the apps' telemetry: container logs bounded on the node and shipped per app, the relay
# that names each container's tenant, container metrics bounded in cardinality; modules/swarm enables it on every worker
#
# Logs. Docker writes each container's output to its own rotated files (the `local` driver), never to the node's
# journal, and drops lines rather than block a container that writes faster than the disk takes them. A promtail
# reads them over the docker api, one job per enabled app, and lets each app through at the lab's per-service rate
# (modules/limits `tenant`); the rest is dropped here, counted per app, before it costs the network, loki or
# another app anything. In loki each app is its own tenant with the same budget, so no app's lines wait on another's.
# Labels stay the ones the journal pipeline gave app logs (container_name, swarm_service, swarm_stack, host), so a
# query or alert over them reads both.
#
# Traces and profiles. A task sends to its node's relay (telemetry.nix relayEndpoints), never to vm-105: the relay is
# vm-105's push doors again, with the tenant of the stack the sending container belongs to, looked up by its
# docker_gwbridge address (lib/relay-tenants.py), whatever header the app sent. An address no app's container holds
# is refused. vm-105 admits this node for the tenants of its cluster's apps only.
#
# The docker api. promtail parses untrusted app output and the tenant map reads container labels: both get a
# read-only proxy of the socket (dockerApi), which passes the few GETs they make and refuses everything else, never
# the docker group.
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
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  inherit (catalog.swarm) cadvisorPort;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # per container on the node: 3 x 10 MB, what `docker service logs` still shows after the shipper read it
  logFileBytes = "10m";
  logFiles = "3";
  # a container writing faster than the driver stores keeps running; above this the newest lines are lost
  logBufferBytes = "4m";
  # a new task's container is found within this; its lines are read from its start, none are lost
  discoveryInterval = "10s";
  shipperJob = "app-logs";
  positions = "/var/lib/promtail/positions.yaml";
  # cpu, memory, network, disk io, oom kills, and processes for the pids limit; the per-cpu and tcp families stay off
  cadvisorMetrics = [ "cpu" "memory" "network" "diskIO" "oom_event" "process" ];
  # vm-105 scrapes every 15s; the 1s default spent a third of a core on a worker with a dozen tasks
  cadvisorHousekeeping = "10s";

  dockerSocket = "/run/docker.sock";
  dockerApi = rec {
    unit = "docker-api-ro";
    group = "docker-api-ro";
    dir = "/run/${unit}";
    socket = "${dir}/docker.sock";
    # what promtail's discovery and log reader and the tenant map ask: version, container and network lists, one
    # container's inspect and logs, the event stream
    paths = "^(/v[0-9.]+)?/(_ping|version|events|networks|networks/[A-Za-z0-9_.-]+|containers/json|containers/[0-9a-f]+/(json|logs))$";
    # a log or event stream stays open as long as the container or dockerd runs
    streamTimeout = "1d";
  };

  relay = rec {
    unit = "telemetry-relay-tenants";
    dir = "/run/${unit}";
    tenants = "tenants.conf";
    doors = lib.getAttrs [ "otlpHttp" "otlpGrpc" "pyroscope" ] telemetry.pushDoors;
  };
  # the apps whose tasks this node runs and which send signals: the tenants vm-105 admits from this node
  nodeApps = lib.concatMap (c: lib.optionals (lib.elem config.homelab.vmid c.workerIds)
    (lib.attrNames (lib.filterAttrs (_: telemetry.sendsSignals) c.apps))) (lib.attrValues catalog.clusters);
  relayTenants = lib.genAttrs nodeApps telemetry.tenantOf;
  collector = inventory.${telemetry.collectorVmid};

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  dockerApiConfig = pkgs.writeText "${dockerApi.unit}.conf" ''
    pid ${dockerApi.dir}/nginx.pid;
    error_log stderr;
    events { }
    http {
      access_log off;
      client_body_temp_path ${dockerApi.dir}/body;
      proxy_temp_path ${dockerApi.dir}/proxy;
      fastcgi_temp_path ${dockerApi.dir}/fastcgi;
      uwsgi_temp_path ${dockerApi.dir}/uwsgi;
      scgi_temp_path ${dockerApi.dir}/scgi;
      server {
        listen unix:${dockerApi.socket};
        location / { return 403; }
        location ~ "${dockerApi.paths}" {
          limit_except GET { deny all; }
          proxy_pass http://unix:${dockerSocket};
          proxy_http_version 1.1;
          proxy_buffering off;
          proxy_read_timeout ${dockerApi.streamTimeout};
        }
      }
    }
  '';

  relayTenantsScript = pkgs.writers.writePython3 relay.unit { flakeIgnore = [ "E501" ]; } (builtins.readFile ./lib/relay-tenants.py);

  # the docker api names a container /<stack>_<service>.<slot>.<task id>
  taskLabel = pattern: label: { source_labels = [ "__meta_docker_container_name" ]; regex = "/${pattern}"; target_label = label; };

  budget = (import ../limits { inherit lib; }).tenant;
  appJob = app: {
    job_name = "app-${app}";
    docker_sd_configs = [{
      host = "unix://${dockerApi.socket}";
      refresh_interval = discoveryInterval;
      filters = [{ name = "label"; values = [ "${telemetry.stackLabel}=${app}" ]; }];
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
    enable = lib.mkEnableOption "the swarm worker's per-app log shipping, telemetry relay and container metrics";
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
      # the relay's address on every node
      bip = "${telemetry.relayAddress}/${toString telemetry.relayPrefixLength}";
    };

    users.groups.${dockerApi.group} = { };
    systemd.services.${dockerApi.unit} = {
      description = "Read-only proxy of the docker api for the node's log shipper and telemetry relay";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.nginx}/bin/nginx -c ${dockerApiConfig} -g 'daemon off;'";
        DynamicUser = true;
        Group = dockerApi.group;
        SupplementaryGroups = [ "docker" ];
        RuntimeDirectory = dockerApi.unit;
        RuntimeDirectoryMode = "0750";
        # the socket nginx creates: its group connects, nobody else
        UMask = "0007";
        Restart = "on-failure";
      };
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
      serviceConfig.SupplementaryGroups = [ dockerApi.group ];
      after = [ "${dockerApi.unit}.service" ];
      requires = [ "${dockerApi.unit}.service" ];
    };

    systemd.services.${relay.unit} = {
      description = "Map the app containers' addresses to their telemetry tenants for the relay";
      wantedBy = [ "multi-user.target" ];
      after = [ "${dockerApi.unit}.service" ];
      requires = [ "${dockerApi.unit}.service" ];
      serviceConfig = {
        ExecStart = "${relayTenantsScript} ${dockerApi.socket} ${relay.dir}/${relay.tenants} ${lib.escapeShellArg (builtins.toJSON relayTenants)}";
        DynamicUser = true;
        SupplementaryGroups = [ dockerApi.group ];
        RuntimeDirectory = relay.unit;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        # dockerd restarting: retried after a second, the delay growing to a minute; the map stays meanwhile
        Restart = "always";
        RestartSec = 1;
        RestartSteps = 6;
        RestartMaxDelaySec = 60;
      };
    };
    # a changed map reaches nginx by a reload, which keeps every open connection
    systemd.paths.${relay.unit} = {
      wantedBy = [ "paths.target" ];
      pathConfig = { PathChanged = "${relay.dir}/${relay.tenants}"; Unit = "${relay.unit}-reload.service"; };
    };
    systemd.services."${relay.unit}-reload" = {
      description = "Reload the telemetry relay's tenant map";
      serviceConfig = { Type = "oneshot"; ExecStart = "${config.systemd.package}/bin/systemctl reload-or-restart nginx.service"; };
    };

    services.nginx = {
      enable = true;
      # an address absent from the map names no tenant: the door refuses it. A glob: before the first map, none
      appendHttpConfig = ''
        geo $relay_tenant {
          default "";
          include ${relay.dir}/*.conf;
        }
      '';
      virtualHosts = lib.mapAttrs' (name: door: lib.nameValuePair "relay-${name}" (telemetry.doorVirtualHost {
        inherit door;
        address = "0.0.0.0";
        tenant = "$relay_tenant";
        upstream = "${collector.ip}:${toString door.port}";
      })) relay.doors;
    };
    # the tasks reach the relay through the bridge they leave by; the node's own address answers nobody on these ports
    networking.firewall.interfaces.docker_gwbridge.allowedTCPPorts = lib.mapAttrsToList (_: door: door.port) relay.doors;

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
