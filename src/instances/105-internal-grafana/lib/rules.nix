# the lab-wide alert rules vm-105 writes itself (telemetry.nix alertType, keyed by uid): the guests, the proxmox host,
# the monitoring pipeline, the shared modules' timestamps and the rules every service gets from its record. A rule over
# one instance's own metrics lives in that instance.nix `alerts`, an app's in its app.nix.
{ lib, telemetry, ntfy, catalog, nodeJob, guestsExpectedUp, monitoringUnitsRegex, services, exportersOf, exporterJobOf, edgeTraefikTarget }:
let
  inherit (telemetry) vmName;

  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # persistent timers catch up within this of a wake; scrape history, since an lxc reports the host's boot time
  upForCatchUp = "min_over_time(up{job=\"${nodeJob}\"}[1h]) == 1";
  guestUp = "up{job=\"${nodeJob}\"} == 1";
  # a nightly job's window: the night itself plus a late start
  nightlyStaleSeconds = 26 * 3600;

  # ext4 data filesystems; /nix/store is a bind of / and would double every alert
  diskSelector = "fstype=\"ext4\",mountpoint!=\"/nix/store\"";
  diskUsedPercent = "100 * (1 - node_filesystem_avail_bytes{${diskSelector}} / node_filesystem_size_bytes{${diskSelector}})";
  # a 3d trend smooths nightly dumps and gc; two weeks is time to order a disk or clean up
  diskForecastWindow = "3d";
  diskForecastHorizonSeconds = 14 * 86400;
  thinpoolDataWarnPercent = 80;
  thinpoolDataCriticalPercent = 90;
  # metadata exhaustion corrupts every thin volume at once, so it warns earlier than data
  thinpoolMetadataPercent = 70;
  # a drive's rated endurance; past it, writes may fail without warning
  nvmeWearRatio = 0.8;
  # the samsung 980's own warning threshold is 82 C; sustained heat this far below it is the airflow failing
  nvmeTemperatureCelsius = 70;

  # a share of wall time in which every task of a guest waited for memory: page-cache thrash, an oom on its way
  # (the 24h worst of a healthy guest is under 0.01, vm-119's nightly oom 0.26)
  memoryStallRatio = 0.1;
  # a unit restarting more often than every 6 minutes for an hour is a crash loop, not a hiccup
  unitRestartsPerHour = 10;

  # thirty guests log several lines a second; under one line in 100 s for a quarter hour, the pipeline stopped
  logLinesMinPerSecond = 0.01;

  # a client bug's steady trickle stays under 5%, a broken backend does not
  app5xxPercent = 5;
  # a page that takes longer than this is broken for its user, whatever it answers
  appLatencySeconds = 2;
  # a task this close to its memory limit for a quarter hour is about to be killed by it
  appSaturationPercent = 90;
  # below this the share is noise: one failed request out of three is not an outage
  app5xxMinRequestsPerSecond = "0.1";
  # the traefik job scrapes every 1m: four samples
  traefikRateWindow = "5m";
  # start-first replaces a task once per deploy: a deploy is two tasks in the window, two quick ones three
  restartLoopWindow = "15m";
  restartLoopTasks = 3;

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  isApp = s: s.app != null;
  alerted = lib.filterAttrs (_: s: s.on.alerts) services;
  exporterJobs = lib.concatLists (lib.mapAttrsToList (key: s: map (exporterJobOf key s) (lib.attrNames (exportersOf s))) alerted);
  appsWithMetric = name: lib.filterAttrs (_: s: isApp s && exportersOf s ? ${name}) alerted;
  regexOf = names: "(${lib.concatStringsSep "|" names})";
  # both ingresses name a route's traefik service after the route: exact names, a prefix would also match <name>-x
  traefikSelector = set: "service=~\"(${lib.concatMapStringsSep "|" (n: "${n}@file") (lib.concatMap (s: s.routes) (lib.attrValues set))})\"";
  alertedApps = lib.attrNames (lib.filterAttrs (_: isApp) alerted);
  alertedAwake = lib.filterAttrs (_: s: isApp s && s.idle.stopAfter == null) alerted;
  builder = vmName catalog.builder;
  requests = filter: "sum by (service) (rate(traefik_service_requests_total{${traefikSelector alerted}${filter}}[${traefikRateWindow}]))";
  busy = "(${requests ""} > ${app5xxMinRequestsPerSecond})";

  # -----------------------------------------------------------------------------
  # RULES
  # -----------------------------------------------------------------------------

  guests = {
    instance_down = {
      title = "Guest offline";
      category = "offline";
      # an idle guest is asleep on purpose (its static config labels it); a powered-off one is not scraped at all
      expr = guestsExpectedUp;
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} is offline";
      description = "node-exporter has been unreachable for 5 minutes. Check `vm status <id>` and the guest's journal.";
    };
    service_down = {
      title = "Service not answering";
      category = "service";
      # a guest that is down is the offline alert's, not one more per route on it
      expr = "probe_success and on (vm) (${guestUp})";
      op = "lt"; threshold = 1;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.service }} on {{ $labels.vm }} does not answer";
      description = "The blackbox probe of the service has failed for 10 minutes while its guest is up.";
    };
    memory_pressure = {
      title = "Guest thrashing";
      category = "offline";
      expr = "max by (vm) (rate(node_pressure_memory_stalled_seconds_total[5m]))";
      threshold = memoryStallRatio;
      for = "10m";
      telegram = true;
      summary = "{{ $labels.vm }}: every task waits for memory {{ humanizePercentage $values.A.Value }} of the time";
      description = "The guest is short of memory: page cache thrash or an oom ahead. Raise its memoryMiB or balloonMiB (instance.nix), or find what grew.";
    };
    unit_restart_loop = {
      title = "Unit restart loop";
      category = "service";
      datasource = "loki";
      rangeSeconds = 3600;
      # systemd logs each scheduled restart as pid 1; the unit is in the line, not in the stream's labels
      expr = "sum by (host, restarted) (count_over_time({job=\"systemd-journal\", unit=\"init.scope\"} |= \"Scheduled restart job\" | regexp \"^(?P<restarted>[^ :]+): Scheduled restart job\" [1h]))";
      threshold = unitRestartsPerHour;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.restarted }} on {{ $labels.host }}: {{ $values.A.Value }} restarts in an hour";
      description = "systemd keeps restarting the unit and `systemctl --failed` never shows it. `journalctl -u {{ $labels.restarted }}` on that guest.";
    };
    ondemand_api_failing = {
      title = "Idle guests cannot be woken";
      category = "offline";
      # the ingresses' wake proxies and reapers (modules/on-demand) write it after every proxmox api call
      expr = "min by (vm) (homelab_ondemand_api_ok)";
      op = "lt"; threshold = 1;
      for = "15m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} cannot reach the Proxmox API: idle guests neither wake nor stop";
      description = "The ingress's on-demand calls to the Proxmox API fail (certificate, token or network). `journalctl -u 'ondemand-*'` on that ingress.";
    };
    ondemand_wake_failed = {
      title = "Idle guest did not wake";
      category = "offline";
      expr = "min by (vm, deployment) (homelab_ondemand_wake_ok)";
      op = "lt"; threshold = 1;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.deployment }} did not answer after its wake";
      description = "The ingress woke it and held the request, but the backend never answered: its route is down. `journalctl -u 'ondemand-*'` on {{ $labels.vm }}.";
    };
    db_dump_stale = {
      title = "Database dump stale";
      category = "backups";
      expr = "(time() - max by (vm, db) (homelab_db_dump_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = nightlyStaleSeconds;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.db }} dump on {{ $labels.vm }}: none in over 26h";
      description = "The nightly db-backup-<name> unit on that guest failed; the snapshot then holds only a live copy.";
    };
    state_mirror_stale = {
      title = "Local state mirror stale";
      category = "backups";
      expr = "(time() - max by (vm, state) (homelab_local_state_mirror_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = nightlyStaleSeconds;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.state }} mirror on {{ $labels.vm }}: none in over 26h";
      description = "The nightly <name>-mirror unit on that guest failed; the NAS copy, and with it the snapshot, is behind the guest's disk.";
    };
    disk_full = {
      title = "Disk almost full";
      category = "storage";
      expr = diskUsedPercent;
      threshold = 90;
      for = "30m";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used";
      description = "A guest filesystem is over 90%. Old generations, journal or images usually; on the nas bulk disk or the download disk, media.";
    };
    disk_critical = {
      title = "Disk full";
      category = "storage";
      expr = diskUsedPercent;
      threshold = 95;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used, writes fail soon";
      description = "Writes on this filesystem fail soon: databases stop, journals and downloads break. Free space now.";
    };
    disk_fill_predicted = {
      title = "Disk fills within two weeks";
      category = "storage";
      expr = "predict_linear(node_filesystem_avail_bytes{${diskSelector}}[${diskForecastWindow}], ${toString diskForecastHorizonSeconds})";
      op = "lt"; threshold = 0;
      # a trend, not a spike: nightly dumps and downloads come and go within hours
      for = "2h";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: full within 14 days at the 3-day trend";
      description = "The free space trend of the last 3 days reaches zero within two weeks. Find what grows before it is full.";
    };
  };

  # the proxmox host's textfile collectors (pve-install.sh): one series per pool or drive, no data until installed
  host = {
    thinpool_data_warn = {
      title = "Thin pool filling";
      category = "storage";
      expr = "homelab_thinpool_data_percent";
      threshold = thinpoolDataWarnPercent;
      for = "30m";
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} data at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Trim guests or grow the pool.";
    };
    thinpool_data_critical = {
      title = "Thin pool almost full";
      category = "storage";
      expr = "homelab_thinpool_data_percent";
      threshold = thinpoolDataCriticalPercent;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} data at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Free space now: fstrim the guests, drop snapshots.";
    };
    thinpool_metadata = {
      title = "Thin pool metadata filling";
      category = "storage";
      expr = "homelab_thinpool_metadata_percent";
      threshold = thinpoolMetadataPercent;
      for = "10m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} metadata at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Full thin pool metadata corrupts the pool. Grow it with lvextend --poolmetadatasize.";
    };
    disk_health = {
      title = "Disk failing";
      category = "storage";
      expr = "smartmon_device_smart_healthy";
      op = "lt"; threshold = 1;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.disk }} on {{ $labels.vm }}: SMART health check failed";
      description = "The drive reports itself as failing. Check that the backups are current, then replace it.";
    };
    nvme_wear = {
      title = "NVMe worn";
      category = "storage";
      expr = "nvme_percentage_used_ratio";
      threshold = nvmeWearRatio;
      for = "1h";
      summary = "{{ $labels.device }} on {{ $labels.vm }}: {{ humanizePercentage $values.A.Value }} of its rated writes used";
      description = "Past its rated endurance an ssd may fail without warning. Plan its replacement.";
    };
    nvme_critical_warning = {
      title = "NVMe critical warning";
      category = "storage";
      # the controller's own bit field: spare below threshold, temperature, reliability, read-only, backup capacitor
      expr = "nvme_critical_warning";
      threshold = 0;
      for = "0m";
      severity = "critical"; telegram = true;
      summary = "{{ $labels.device }} on {{ $labels.vm }}: critical warning {{ $values.A.Value }}";
      description = "The drive raised a critical warning. Every guest disk and the local backup repository share this volume group: check the off-site copy, then `nvme smart-log /dev/{{ $labels.device }}` on the host.";
    };
    nvme_temperature = {
      title = "NVMe running hot";
      category = "storage";
      expr = "nvme_temperature_celsius";
      threshold = nvmeTemperatureCelsius;
      for = "15m";
      telegram = true;
      summary = "{{ $labels.device }} on {{ $labels.vm }}: {{ $values.A.Value }} C for 15 minutes";
      description = "The drive is near its throttling point; heat shortens its life. Check the case airflow and the heatsink.";
    };
  };

  monitoring = {
    # dead man's switch: always firing, vm-203 alerts when it stops arriving on the heartbeat topic
    watchdog = {
      title = "Watchdog";
      category = "heartbeat";
      expr = "up{job=\"prometheus\"}";
      threshold = 0;
      for = "0m";
      # prometheus not answering resolves it, which stops the heartbeat
      execErr = "OK";
      summary = "vm-105 evaluates rules and delivers notifications";
      description = "Always firing on purpose. Its absence on ntfy topic ${ntfy.topics.heartbeat} is the alert.";
    };
    monitoring_unit_down = {
      title = "Monitoring unit down";
      category = "monitoring";
      expr = "node_systemd_unit_state{state=\"active\",name=~\"${monitoringUnitsRegex}\"}";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.name }} on vm-105 is not active";
      description = "A part of the metrics, logs or alerting pipeline stopped; alerts that need it cannot fire. `systemctl status {{ $labels.name }}` on vm-105.";
    };
    logs_not_arriving = {
      title = "No logs arriving";
      category = "monitoring";
      expr = "sum(rate(loki_distributor_lines_received_total[15m]))";
      op = "lt"; threshold = logLinesMinPerSecond;
      for = "15m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "Loki has received no log lines for 15 minutes";
      description = "journal-remote, promtail or loki on vm-105 stopped forwarding; the log alerts see nothing. `journalctl -u promtail -u systemd-journal-remote` on vm-105.";
    };
    promtail_dropping = {
      title = "Log lines dropped";
      category = "monitoring";
      expr = "sum by (vm, reason) (increase(promtail_dropped_entries_total[1h]))";
      threshold = 0;
      for = "0m";
      summary = "promtail on {{ $labels.vm }} dropped {{ printf \"%.0f\" $values.A.Value }} lines in the last hour ({{ $labels.reason }})";
      description = "Loki refused or promtail gave up on log lines, so they are gone. `journalctl -u promtail` on that guest.";
    };
  };

  # every service's record (catalog.services): the same rules for a nixos guest's routes and an app's
  serviceRules = lib.optionalAttrs (exporterJobs != [ ]) {
    app_target_down = {
      title = "Service metrics unreachable";
      category = "service";
      # an app asleep (idle) or a guest that is down has no exporter to reach; the guest is the offline alert's
      expr = "up{job=~\"${regexOf exporterJobs}\"} unless on (app) homelab_app_idle_stopped == 1 and on (vm) (${guestUp})";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.job }} on {{ $labels.vm }} does not answer";
      description = "Prometheus has not reached this exporter for 5 minutes: the service is down, crash looping or not published.";
    };
  } // lib.optionalAttrs (alerted != { }) {
    app_5xx = {
      title = "Service answering 5xx";
      category = "service";
      expr = "100 * (${requests ",code=~\"5..\""} / ${requests ""}) and on (service) ${busy}";
      threshold = app5xxPercent;
      for = "10m";
      telegram = true;
      summary = "{{ $labels.service }}: {{ printf \"%.0f\" $values.A.Value }}% of requests fail with 5xx";
      description = "Over ${toString app5xxPercent}% of the requests traefik sends this route fail with 5xx. Its board (Services) holds its logs.";
    };
    app_slow = {
      title = "Service answering slowly";
      category = "service";
      expr = "histogram_quantile(0.95, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket{${traefikSelector alerted}}[${traefikRateWindow}])))"
        + " and on (service) ${busy}";
      threshold = appLatencySeconds;
      for = "15m";
      summary = "{{ $labels.service }}: 95% of requests take up to {{ printf \"%.1f\" $values.A.Value }}s";
      description = "The route's p95 latency at its ingress is above ${toString appLatencySeconds}s. Its board shows whether it is cpu-throttled, out of memory or waiting on a store.";
    };
  } // lib.optionalAttrs (alertedApps != [ ]) {
    app_restart_loop = {
      title = "App container restart loop";
      category = "apps";
      # each restart is a new task container, so the distinct names seen in the window
      expr = "count by (swarm_service) (count_over_time(container_start_time_seconds{swarm_stack=~\"${regexOf alertedApps}\"}[${restartLoopWindow}]))";
      threshold = restartLoopTasks;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.swarm_service }}: {{ $values.A.Value }} tasks in ${restartLoopWindow}, restart loop";
      description = "Swarm keeps replacing this service's task. `docker service ps --no-trunc <service>` on the app's manager shows why.";
    };
    app_deploy_failed = {
      title = "App deploy failed";
      category = "apps";
      # only the builder's own file: another guest's stale one must not outvote it
      expr = "min by (app) (homelab_app_deploy_ok{vm=\"${builder}\",app=~\"${regexOf alertedApps}\"})";
      op = "lt"; threshold = 1;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.app }}: the last build or deploy failed, the previous version keeps running";
      description = "The builder on ${builder} could not build or deploy the app's newest commit; it retries with backoff (5 min, doubling to 6 h) and on every new commit, `app-builder-redeploy <app>` forces it. `journalctl -u app-builder -u 'app-builder@*'` there.";
    };
    app_swarm_deploy_failed = {
      title = "App deploy failed on the manager";
      category = "apps";
      # a deploy the builder already reports as failed pages once, from there
      expr = "min by (app, vm) (homelab_swarm_deploy_ok{app=~\"${regexOf alertedApps}\"}) unless on (app) (homelab_app_deploy_ok{vm=\"${builder}\"} == 0)";
      op = "lt"; threshold = 1;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.app }}: {{ $labels.vm }} could not roll out the app, the previous version keeps running";
      description = "swarm-deploy refused, could not roll out, or the swarm rolled back the app. `journalctl -t swarm-deploy -u swarm-converge` on the manager {{ $labels.vm }}.";
    };
    app_unreachable = {
      title = "App has no healthy backend";
      category = "apps";
      # an idle app's routes go through the wake proxy, which holds its first request until it answers
      expr = "max by (service) (traefik_service_server_up{instance=\"${edgeTraefikTarget}\",${traefikSelector alertedAwake}})";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.service }}: no node answers its health check";
      description = "The edge's health check fails on every node of the app's cluster: the app is down for its users. `docker service ps <app>_<service>` on its manager.";
    };
    app_memory_saturated = {
      title = "App task near its memory limit";
      category = "apps";
      expr = let tasks = "swarm_stack=~\"${regexOf alertedApps}\""; in
        "100 * max by (swarm_service) (container_memory_working_set_bytes{${tasks}} / (container_spec_memory_limit_bytes{${tasks}} > 0))";
      threshold = appSaturationPercent;
      for = "15m";
      summary = "{{ $labels.swarm_service }}: {{ printf \"%.0f\" $values.A.Value }}% of its memory limit";
      description = "The task reclaims and will be killed inside its own limit. Raise apps.<app>.resources.<service>.memoryMiB (and its reservation) or fix the leak.";
    };
  } // lib.optionalAttrs (appsWithMetric "postgres" != { }) {
    app_postgres_down = {
      title = "App database down";
      category = "apps";
      expr = "min by (app) (pg_up)";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.app }}: postgres down";
      description = "postgres_exporter answers but cannot reach postgres. Check the stack's postgres service on its nodes.";
    };
  } // lib.optionalAttrs (appsWithMetric "redis" != { }) {
    app_redis_down = {
      title = "App cache down";
      category = "apps";
      expr = "min by (app) (redis_up)";
      op = "lt"; threshold = 1;
      severity = "critical"; telegram = true;
      summary = "{{ $labels.app }}: redis down";
      description = "redis_exporter answers but cannot reach redis. Check the stack's redis service on its nodes.";
    };
  };
in
guests // host // monitoring // serviceRules
