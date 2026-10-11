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
# Traces and profiles. A task never reaches vm-105 (modules/swarm DOCKER-USER); it sends to the relay on its own node
# (telemetry.nix relayEndpoints), which sets the tenant from the sender's address: the resolver maps each task
# container's docker_gwbridge address to the app swarm named its service after (<app>_<service>, which no compose
# file chooses), on every container start and stop. A request from any other address is refused, never guessed.
# vm-105 then admits from this node only the tenants of the apps its cluster runs.
#
# The docker api. The shipper and the resolver read untrusted names and lines; they get a proxy of the socket that
# passes the reads they make (listing, inspecting, logs, events) and nothing else, never the docker group.
#
# Rejected: the docker journald driver. Every container logs as docker.service, so journald's per-unit rate limit
# suppressed every app on the node once one flooded, and the upload filled vm-105's journal-remote directory, which
# ignores its size cap between vacuums.
{ config, lib, pkgs, inventory, catalog, ... }:
let
  cfg = config.homelab.appTelemetry;
  telemetry = import ./telemetry.nix { inherit lib inventory; };
  inherit (catalog.swarm) cadvisorPort;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # per container on the node: 3 x 10 MB, what `docker service logs` still shows after the shipper read it
  logFileBytes = "10m";
  logFiles = "3";
  # a container writing faster than the driver stores keeps running; above this the newest lines are lost
  logBufferBytes = "4m";
  dockerSocket = "/run/docker.sock";
  readApi = "docker-read";
  readSocket = "/run/${readApi}/docker.sock";
  # what promtail's discovery and log tail and the resolver call, with or without the api version prefix
  readPaths = "^(/v[0-9.]+)?/(_ping|version|events|containers/json|containers/[0-9a-f]+/(json|logs)|networks|networks/[A-Za-z0-9_.-]+)$";
  # swarm attaches every task to this bridge for its traffic off the overlays: the relay sees the task's address there
  gatewayBridge = "docker_gwbridge";
  serviceNameLabel = "com.docker.swarm.service.name";
  relay = "app-relay";
  relayDir = "/run/${relay}";
  relayTenants = "${relayDir}/tenants.map";
  relayPorts = with telemetry.ports; { inherit otlpHttp otlpGrpc pyroscope; };
  collector = inventory.${telemetry.collectorVmid};
  # a stream of logs or events stays open as long as the node runs
  streamTimeout = "1d";
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
  signalApps = lib.attrNames (lib.filterAttrs (_: telemetry.sendsSignals) catalog.apps);

  # an nginx of its own per unit, unprivileged: its pid and buffers in the unit's runtime directory
  nginxConf = dir: body: ''
    daemon off;
    pid ${dir}/nginx.pid;
    error_log stderr warn;
    events { }
    http {
      access_log off;
      client_body_temp_path ${dir}/body;
      proxy_temp_path ${dir}/proxy;
      fastcgi_temp_path ${dir}/fastcgi;
      uwsgi_temp_path ${dir}/uwsgi;
      scgi_temp_path ${dir}/scgi;
    ${body}
    }
  '';
  nginxUnit = name: conf: {
    ExecStart = "${pkgs.nginx}/bin/nginx -c ${pkgs.writeText "${name}.conf" conf} -e stderr";
    ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
    Restart = "always";
    RestartSec = 5;
  };

  readApiConf = nginxConf "/run/${readApi}" ''
    server {
      listen unix:${readSocket};
      location ~ "${readPaths}" {
        limit_except GET { deny all; }
        proxy_pass http://unix:${dockerSocket}:;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout ${streamTimeout};
      }
      location / { return 403; }
    }
  '';

  relayLocations = door: proxy: lib.concatMapStrings (path: ''
      location = ${path} {
        limit_except POST { deny all; }
        if ($tenant = "") { return 403; }
        ${proxy}
      }
  '') telemetry.pushPaths.${door};
  relayConf = nginxConf relayDir ''
    map $remote_addr $tenant {
      default "";
      include ${relayTenants};
    }
    server {
      listen ${toString relayPorts.otlpHttp};
      client_max_body_size ${toString budget.traceBurstBytes};
      location / { return 404; }
    ${relayLocations "otlpHttp" ''
        proxy_set_header ${telemetry.tenantHeader} $tenant;
        proxy_pass ${telemetry.urls.otlpHttp};
    ''}
    }
    server {
      listen ${toString relayPorts.otlpGrpc};
      http2 on;
      client_max_body_size ${toString budget.traceBurstBytes};
      location / { return 404; }
    ${relayLocations "otlpGrpc" ''
        grpc_set_header ${telemetry.tenantHeader} $tenant;
        grpc_pass grpc://${collector.ip}:${toString telemetry.ports.otlpGrpc};
    ''}
    }
    server {
      listen ${toString relayPorts.pyroscope};
      client_max_body_size ${toString budget.profileBurstBytes};
      location / { return 404; }
    ${relayLocations "pyroscope" ''
        proxy_set_header ${telemetry.tenantHeader} $tenant;
        proxy_pass ${telemetry.urls.pyroscope};
    ''}
    }
  '';

  # rewrites the relay's address map from the running task containers, then on every container start and stop
  relayResolver = pkgs.writeShellApplication {
    name = "${relay}-resolver";
    runtimeInputs = [ config.virtualisation.docker.package pkgs.coreutils ];
    runtimeEnv.DOCKER_HOST = "unix://${readSocket}";
    text = ''
      apps=" ${toString signalApps} "
      resolve() {
        tmp=$(mktemp ${relayTenants}.XXXXXX)
        docker network inspect ${gatewayBridge} \
            --format '{{range $id, $c := .Containers}}{{$id}} {{$c.IPv4Address}}{{println}}{{end}}' |
          while read -r id address; do
            [ -n "$address" ] || continue
            # the bridge's own sandboxes are no container
            service=$(docker container inspect --format '{{index .Config.Labels "${serviceNameLabel}"}}' "$id" 2>/dev/null) || continue
            app=''${service%%_*}
            case "$apps" in *" $app "*) echo "''${address%/*} ${telemetry.tenantOf "\${app}"};" ;; esac
          done > "$tmp"
        chmod 0644 "$tmp"
        mv "$tmp" ${relayTenants}
        kill -HUP "$(cat ${relayDir}/nginx.pid)"
      }
      since=$(date +%s)
      resolve
      docker events --since "$since" --filter type=container --filter event=start --filter event=die --format '{{.ID}}' |
        while read -r _; do resolve; done
    '';
  };
  appJob = app: {
    job_name = "app-${app}";
    docker_sd_configs = [{
      host = "unix://${readSocket}";
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
    relayConfig = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      internal = true;
      default = relayConf;
      description = "The relay's nginx configuration; the telemetry law reads it here.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.daemon.settings = {
      bip = telemetry.relayBridge;
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
      serviceConfig.SupplementaryGroups = [ readApi ];
      after = [ "${readApi}.service" ];
      wants = [ "${readApi}.service" ];
    };

    users.users.${readApi} = { isSystemUser = true; group = readApi; extraGroups = [ "docker" ]; };
    users.groups.${readApi} = { };
    systemd.services.${readApi} = {
      description = "Read-only proxy of the docker api";
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = nginxUnit readApi readApiConf // {
        User = readApi;
        Group = readApi;
        RuntimeDirectory = readApi;
        RuntimeDirectoryMode = "0750";
        # the socket nginx creates: its group (the readers) may connect, nobody else
        UMask = "0007";
      };
    };

    users.users.${relay} = { isSystemUser = true; group = relay; extraGroups = [ readApi ]; };
    users.groups.${relay} = { };
    systemd.tmpfiles.rules = [
      "d ${relayDir} 0750 ${relay} ${relay} -"
      "f ${relayTenants} 0644 ${relay} ${relay} -"
    ];
    systemd.services.${relay} = {
      description = "Relay of the apps' traces and profiles, tenant by sender";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = nginxUnit relay relayConf // { User = relay; Group = relay; };
    };
    systemd.services."${relay}-resolver" = {
      description = "Map the task containers' addresses to their apps' tenants for the relay";
      after = [ "${relay}.service" "${readApi}.service" ];
      requires = [ "${relay}.service" ];
      wants = [ "${readApi}.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = lib.getExe relayResolver;
        User = relay;
        Group = relay;
        Restart = "always";
        RestartSec = 5;
      };
    };
    # only the tasks reach the relay, over the bridge swarm gives them
    networking.firewall.interfaces.${gatewayBridge}.allowedTCPPorts = lib.attrValues relayPorts;

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
