# the lab-wide alert rules, keyed by uid; a rule over one instance's own metrics lives in its instance.nix `alerts`
{
  lib,
  telemetry,
  ntfy,
  catalog,
  nodeJob,
  guestsExpectedUp,
  monitoringUnitsRegex,
  services,
  exportersOf,
  exporterJobOf,
  edgeTraefikTarget,
  upstreamJob,
  proxmoxVm,
  proxmoxAddress,
  operatorSources,
  ingressJobs,
}:
let
  inherit (telemetry) vmName;

  # persistent timers catch up within this of a wake; scrape history, since an lxc reports the host's boot time
  upForCatchUp = "min_over_time(up{job=\"${nodeJob}\"}[1h]) == 1";
  guestUp = "up{job=\"${nodeJob}\"} == 1";
  # a nightly job's window: the night itself plus a late start
  nightlyStaleSeconds = 26 * 3600;

  # ext4 data filesystems; /nix/store is a bind of / and would double every alert
  diskSelector = "fstype=\"ext4\",mountpoint!=\"/nix/store\"";
  diskFreePercent = selector: "100 * node_filesystem_avail_bytes{${selector}} / node_filesystem_size_bytes{${selector}}";
  diskUsedPercent = "100 - ${diskFreePercent diskSelector}";
  # a 63 GiB guest disk at 85% has 9 GiB left: one full archrepo rebuild (7.6 GiB) still fits, a second night does not
  diskWarnPercent = 85;
  diskCriticalPercent = 95;
  # a week's trend smooths nightly dumps, builds and gc, which a regression over days takes for a slope; two weeks is
  # time to order a disk or clean up
  diskForecastWindow = "7d";
  diskForecastHorizonSeconds = 14 * 86400;
  # with half the disk free a forecast fill is a step (an import, a build), not a trend; disk_full catches a runaway
  diskForecastFreePercentMax = 50;
  # an idle guest's samples are its short wakes, each after a reboot: no trend, and stale while it sleeps
  diskForecastSelector = "${diskSelector},idle=\"\"";
  # a buffered upload holds at most its body limit there briefly; a gigabyte that stays is leaked responses
  ingressSpoolBytesMax = 1024 * 1024 * 1024;
  # traefik renews at 30 days left; two weeks of failed retries is time to fix the dns token by hand
  certificateExpiryDaysMin = 14;
  # an exposed address collects tens of new bans a day from scanners; a hundred in an hour is a campaign or a gate
  # banning people
  ingressBansPerHourMax = 100;
  thinpoolDataWarnPercent = 80;
  thinpoolDataCriticalPercent = 90;
  # metadata exhaustion corrupts every thin volume at once, so it warns earlier than data
  thinpoolMetadataPercent = 70;
  # a drive's rated endurance; past it, writes may fail without warning
  nvmeWearRatio = 0.8;
  # the samsung 980's own warning threshold is 82 C; sustained heat this far below it is the airflow failing
  nvmeTemperatureCelsius = 70;
  # nvme1 averaged 0.6% of its power-on time throttled (43823 s in 2019 h) while it overheated; a cooled drive makes none
  nvmeThrottleSecondsPerHour = 60;
  # a host event (a boot, an unsafe shutdown) fires this long, then resolves by itself
  hostEventWindow = "1h";
  hostEventWindowSeconds = 3600;

  # a share of wall time in which every task of a guest waited for memory: page-cache thrash, an oom on its way
  # (the 24h worst of a healthy guest is under 0.01, vm-112's nightly oom 0.26)
  memoryStallRatio = 0.1;
  # a unit restarting more often than every 6 minutes for an hour is a crash loop, not a hiccup
  unitRestartsPerHour = 10;

  # the builder polls every few minutes and bounds each app; two hours without a full pass is a hung run
  builderStaleSeconds = 2 * 3600;
  # the host's chipset watchdog (pve-install.nu WATCHDOG_IDENTITY), the only one that resets a hung kernel
  hostWatchdog = "SP5100 TCO timer";

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

  isApp = s: s.app != null;
  alerted = lib.filterAttrs (_: s: s.on.alerts) services;
  exporterJobs = lib.concatLists (
    lib.mapAttrsToList (key: s: map (exporterJobOf key s) (lib.attrNames (exportersOf s))) alerted
  );
  appsWithMetric = name: lib.filterAttrs (_: s: isApp s && exportersOf s ? ${name}) alerted;
  regexOf = names: "(${lib.concatStringsSep "|" names})";
  # both ingresses name a route's traefik service after the route: exact names, a prefix would also match <name>-x
  traefikSelector =
    set:
    "service=~\"(${lib.concatMapStringsSep "|" (n: "${n}@file") (lib.concatMap (s: s.routes) (lib.attrValues set))})\"";
  alertedApps = lib.attrNames (lib.filterAttrs (_: isApp) alerted);
  alertedAwake = lib.filterAttrs (_: s: isApp s && s.idle.stopAfter == null) alerted;
  builder = vmName catalog.builder;
  requests =
    filter:
    "sum by (service) (rate(traefik_service_requests_total{${traefikSelector alerted}${filter}}[${traefikRateWindow}]))";
  busy = "(${requests ""} > ${app5xxMinRequestsPerSecond})";
  sshAcceptedPattern = "^Accepted (?P<method>[^ ]+) for (?P<user>[^ ]+) from (?P<source>[^ ]+) port";
  operatorSourceFilter = lib.concatMapStringsSep " and " (s: "source != ip(\"${s}\")") operatorSources;

  guests = {
    instance_down = {
      title = "Guest offline";
      category = "offline";
      # an idle guest is asleep on purpose (its static config labels it); a powered-off one is not scraped at all
      expr = guestsExpectedUp;
      op = "lt";
      threshold = 1;
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} is offline";
      description = "node-exporter has been unreachable for 5 minutes. `ssh root@${proxmoxAddress} qm list` shows whether the guest runs, then read its journal.";
    };
    service_down = {
      title = "Service not answering";
      category = "service";
      # a guest that is down is the offline alert's, not one more per route on it
      expr = "probe_success and on (vm) (${guestUp})";
      op = "lt";
      threshold = 1;
      for = "10m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.service }} on {{ $labels.vm }} does not answer";
      description = "The blackbox probe of the service has failed for 10 minutes while its guest is up.";
    };
    upstream_unavailable = {
      title = "Upstream unavailable";
      category = "upstream";
      expr = "probe_success{job=\"${upstreamJob}\"}";
      op = "lt";
      threshold = 1;
      for = "15m";
      summary = "{{ $labels.upstream }} unavailable";
      description = "The lab has not reached this third-party service (src/modules/upstream/lib/upstreams.nix) for 15 minutes. Its callers skip their runs and keep their last state; nothing to do unless it lasts.";
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
    unit_failed = {
      title = "Unit failed";
      category = "service";
      # modules/base: a series per unit while it stays failed
      expr = "max by (vm, unit) (homelab_systemd_failed_units)";
      threshold = 0;
      for = "15m";
      summary = "{{ $labels.unit }} on {{ $labels.vm }} failed";
      description = "The unit failed and stayed failed: a oneshot's error or a crashed service systemd gave up on. `systemctl status {{ $labels.unit }}` and `journalctl -u {{ $labels.unit }}` on that guest.";
    };
    oom_kill = {
      title = "Out of memory kill";
      category = "offline";
      expr = "max by (vm) (increase(node_vmstat_oom_kill[1h]))";
      threshold = 0;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.vm }}: {{ printf \"%.0f\" $values.A.Value }} processes killed for memory in the last hour";
      description = "The kernel killed a process to free memory; a job or service died with it. `journalctl -k --grep oom` on that guest names it; raise its memoryMiB or balloonMiB (instance.nix).";
    };
    system_drift = {
      title = "Host off its deployed generation";
      category = "service";
      # modules/base compares the running system with the one sync.nu last deployed
      expr = "max by (vm) (homelab_system_drift)";
      threshold = 0;
      for = "1h";
      summary = "{{ $labels.vm }} runs another generation than sync.nu deployed";
      description = "A hand-run switch or rollback changed the host, or it booted an older generation. `readlink /run/current-system` against /var/lib/homelab/deployed-toplevel there; `./sync.nu` puts it back.";
    };
    guard_refused = {
      title = "Guard refused a connection";
      category = "attack";
      datasource = "loki";
      rangeSeconds = 3600;
      # modules/network.nix logs each refusal of a guarded port, ssh and the node exporter among them
      expr = "sum by (host) (count_over_time({job=\"systemd-journal\"} |= \"guard-refused: \" [1h]))";
      threshold = 0;
      for = "0m";
      summary = "{{ $labels.host }} refused {{ $values.A.Value }} connections to its guarded ports in the last hour";
      description = "A source no grant names knocked on a guarded port: a missing grant, or a guest probing its neighbours. `journalctl -k --grep guard-refused` on that guest names the source and the port.";
    };
    ondemand_api_failing = {
      title = "Idle guests cannot be woken";
      category = "offline";
      # the ingresses' wake proxies and reapers (modules/on-demand) write it after every proxmox api call
      expr = "min by (vm) (homelab_ondemand_api_ok)";
      op = "lt";
      threshold = 1;
      for = "15m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} cannot reach the Proxmox API: idle guests neither wake nor stop";
      description = "The ingress's on-demand calls to the Proxmox API fail (certificate, token or network). `journalctl -u 'ondemand-*'` on that ingress.";
    };
    ondemand_wake_failed = {
      title = "Idle guest did not wake";
      category = "offline";
      # the last wake of each route (modules/on-demand); a wake that succeeds later resolves it
      expr = "min by (vm, target) (homelab_ondemand_wake_ok)";
      op = "lt";
      threshold = 1;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.target }} did not answer after its wake";
      description = "The ingress woke it and held the request, but the backend never answered: its route is down until a wake succeeds. `journalctl -u 'ondemand-*'` on {{ $labels.vm }}.";
    };
    db_dump_stale = {
      title = "Database dump stale";
      category = "backups";
      expr = "(time() - max by (vm, db) (homelab_db_dump_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = nightlyStaleSeconds;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.db }} dump on {{ $labels.vm }}: none in over 26h";
      description = "The nightly db-backup-<name> unit on that guest failed; the snapshot then holds only a live copy.";
    };
    state_mirror_stale = {
      title = "Local state mirror stale";
      category = "backups";
      expr = "(time() - max by (vm, state) (homelab_local_state_mirror_last_success_timestamp_seconds)) and on (vm) ${upForCatchUp}";
      threshold = nightlyStaleSeconds;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.state }} mirror on {{ $labels.vm }}: none in over 26h";
      description = "The nightly <name>-mirror unit on that guest failed; the NAS copy, and with it the snapshot, is behind the guest's disk.";
    };
    disk_full = {
      title = "Disk almost full";
      category = "storage";
      expr = diskUsedPercent;
      threshold = diskWarnPercent;
      for = "30m";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used";
      description = "A guest filesystem is over ${toString diskWarnPercent}%. Old generations, journal or images usually; on the nas bulk disk or the download disk, media.";
    };
    disk_critical = {
      title = "Disk full";
      category = "storage";
      expr = diskUsedPercent;
      threshold = diskCriticalPercent;
      for = "10m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: {{ printf \"%.0f\" $values.A.Value }}% used, writes fail soon";
      description = "Writes on this filesystem fail soon: databases stop, journals and downloads break. Free space now.";
    };
    disk_fill_predicted = {
      title = "Disk fills within two weeks";
      category = "storage";
      # the free share is a current sample: a guest that went down has none, while its window's samples outlive it
      expr =
        "predict_linear(node_filesystem_avail_bytes{${diskForecastSelector}}[${diskForecastWindow}], ${toString diskForecastHorizonSeconds})"
        + " and ${diskFreePercent diskForecastSelector} < ${toString diskForecastFreePercentMax}";
      op = "lt";
      threshold = 0;
      # a trend, not a spike: nightly dumps, builds and downloads come and go within hours
      for = "6h";
      summary = "{{ $labels.vm }} {{ $labels.mountpoint }}: full within 14 days at the 7-day trend";
      description = "Less than half of this filesystem is free and its free space trend of the last 7 days reaches zero within two weeks. Find what grows before it is full.";
    };
    ingress_spool = {
      title = "Ingress spool files pile up";
      category = "storage";
      expr = "max by (vm) (homelab_traefik_spool_bytes)";
      threshold = ingressSpoolBytesMax;
      for = "15m";
      telegram = true;
      summary = "{{ $labels.vm }}: {{ humanize1024 $values.A.Value }}B of traefik buffering files in /tmp";
      description = "traefik's buffering middleware (the body limit) leaks temp-multibuf-* files when a copy fails; past the disk they fail every buffered request with 500. `systemctl restart traefik` clears its private /tmp.";
    };
    ingress_ban_surge = {
      title = "Unusual ban rate";
      category = "attack";
      # each ingress's gate counts a crowdsec ban the first time it enforces it (modules/traefik lib/gate)
      expr = "max by (vm) (increase(homelab_gate_bans_total[1h]))";
      threshold = ingressBansPerHourMax;
      for = "10m";
      telegram = true;
      summary = "{{ $labels.vm }}: {{ $values.A.Value | printf \"%.0f\" }} new bans in the last hour";
      description = "Far more clients were banned than scanners cause. Check `cscli alerts list` and `cscli decisions list` in the crowdsec container for one scenario or one range behind them; a wave of a scenario on real users (the rate-limited or captcha-failed ladder signals) means a limit is too tight.";
    };
    ingress_exporter_down = {
      title = "Ingress companion unreachable";
      category = "monitoring";
      # the access log shipper, crowdsec and anubis beside each ingress's traefik
      expr = "up{job=~\"${regexOf ingressJobs}\"}";
      op = "lt";
      threshold = 1;
      for = "10m";
      summary = "{{ $labels.job }} on {{ $labels.vm }} does not answer";
      description = "Without the access log shipper the ingress's requests reach no board or alert, without crowdsec no ban is enforced. `systemctl status promtail` and `podman ps` on {{ $labels.vm }}.";
    };
    certificate_expiring = {
      title = "Ingress certificate expiring";
      category = "service";
      expr = "min by (instance) ((traefik_tls_certs_not_after - time()) / 86400)";
      op = "lt";
      threshold = certificateExpiryDaysMin;
      for = "1h";
      telegram = true;
      summary = "{{ $labels.instance }}: the certificate expires in {{ printf \"%.0f\" $values.A.Value }} days";
      description = "traefik renews 30 days ahead and retries; renewals failing for weeks (cloudflare dns or let's encrypt unavailable, a revoked token) leave this. `journalctl -u traefik | grep -i acme` on the ingress.";
    };
  };

  # the proxmox host's textfile collectors (pve-install.nu): one series per pool or drive, no data until installed
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
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} data at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Every guest disk lives in this pool; a full pool stops all their writes at once. Free space now: fstrim the guests, drop snapshots.";
    };
    thinpool_metadata = {
      title = "Thin pool metadata filling";
      category = "storage";
      expr = "homelab_thinpool_metadata_percent";
      threshold = thinpoolMetadataPercent;
      for = "10m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} thin pool {{ $labels.vg }} metadata at {{ printf \"%.0f\" $values.A.Value }}%";
      description = "Full thin pool metadata corrupts the pool. Grow it with lvextend --poolmetadatasize.";
    };
    disk_health = {
      title = "Disk failing";
      category = "storage";
      expr = "smartmon_device_smart_healthy";
      op = "lt";
      threshold = 1;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.disk }} on {{ $labels.vm }}: SMART health check failed";
      description = "The drive reports itself as failing. Check that the backups are current, then replace it.";
    };
    smartd_warning = {
      title = "Disk warning";
      category = "storage";
      # smartd repeats a warning daily while it lasts (pve-install.nu), so a day without one ends it
      expr = "time() - max by (vm, device, type, message) (homelab_smartd_warning_timestamp_seconds)";
      op = "lt";
      threshold = nightlyStaleSeconds;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.device }} on {{ $labels.vm }}: smartd warns ({{ $labels.type }}{{ with $labels.message }}: {{ . }}{{ end }})";
      description = "smartd found a failed self-test, a prefail attribute or a temperature limit. `smartctl -a {{ $labels.device }}` on the host, then check that the backups are current.";
    };
    ossec_down = {
      title = "Intrusion detection down";
      category = "monitoring";
      expr = "homelab_ossec_up";
      op = "lt";
      threshold = 1;
      # its textfile is rewritten every 5 minutes: three runs in a row saw no analysisd
      for = "15m";
      telegram = true;
      summary = "OSSEC on {{ $labels.vm }} is not running";
      description = "ossec-analysisd is down, so the hypervisor's intrusion detection sees nothing. `systemctl restart ossec` on the host, then `/var/ossec/logs/ossec.log`.";
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
      severity = "critical";
      telegram = true;
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
    nvme_throttling = {
      title = "NVMe throttling";
      category = "storage";
      # the controller's own throttled time: it throttles at idle composite temperatures too, a hot sensor of its own
      expr = "max by (vm, device) (increase(homelab_nvme_thermal_throttle_seconds_total[1h]))";
      threshold = nvmeThrottleSecondsPerHour;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.device }} on {{ $labels.vm }}: throttled {{ printf \"%.0f\" $values.A.Value }} s in the last hour";
      description = "The drive slows every guest disk on it to cool down. Give it a heatsink or airflow; `nvme smart-log /dev/{{ $labels.device }}` on the host shows the thermal management times.";
    };
    nvme_over_warning_temperature = {
      title = "NVMe over its warning temperature";
      category = "storage";
      # the drive counts every minute over its own limit, which a 5 minute scrape of the temperature misses
      expr = "max by (vm, device) (increase(homelab_nvme_warning_temperature_seconds_total[1h]))";
      threshold = 0;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.device }} on {{ $labels.vm }}: {{ printf \"%.0f\" $values.A.Value }} s over its warning temperature in the last hour";
      description = "The drive ran past the temperature its maker rates for sustained use. Check the case airflow and the heatsink now.";
    };
    nvme_unsafe_shutdown = {
      title = "Host went down uncleanly";
      category = "offline";
      # the counter rises at the boot after a power loss or a hang; the comparison reaches back past any outage
      expr = "max by (vm, device) (nvme_unsafe_shutdowns_total - last_over_time(nvme_unsafe_shutdowns_total[30d] offset ${hostEventWindow}))";
      threshold = 0;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }} lost power or hung: {{ $labels.device }} counts an unsafe shutdown";
      description = "The host ended without shutting down. `journalctl -b -1 -n 100` on the host shows its last lines, `journalctl --list-boots` how long it was gone; check that every guest came back.";
    };
    host_rebooted = {
      title = "Host rebooted";
      category = "offline";
      expr = "time() - node_boot_time_seconds{job=\"${nodeJob}\",vm=\"${proxmoxVm}\"}";
      op = "lt";
      threshold = hostEventWindowSeconds;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.vm }} booted {{ humanizeDuration $values.A.Value }} ago";
      description = "Every guest restarted with it. A reboot nobody ran is a watchdog reset or a crash: `journalctl -b -1 -n 100` on the host.";
    };
    host_watchdog_unarmed = {
      title = "Host watchdog not armed";
      category = "offline";
      # a host whose exporter is down is the offline alert's
      expr = "absent(node_watchdog_info{vm=\"${proxmoxVm}\",identity=\"${hostWatchdog}\",state=\"active\"}) and on () (up{job=\"${nodeJob}\",vm=\"${proxmoxVm}\"} == 1)";
      threshold = 0;
      for = "1h";
      summary = "{{ $labels.vm }}: the ${hostWatchdog} is not armed";
      description = "A hung kernel waits for a power cycle instead of resetting the board. pve-install.nu arms it from the next host boot, or now: `systemctl stop watchdog-mux && rmmod softdog && systemctl start watchdog-mux` on the host.";
    };
    host_security_upgrades = {
      title = "Host security upgrades pending";
      category = "service";
      expr = "sum(apt_upgrades_pending{vm=\"${proxmoxVm}\",origin=~\".*security.*\"})";
      threshold = 0;
      for = "7d";
      summary = "{{ $labels.vm }}: {{ printf \"%.0f\" $values.A.Value }} security upgrades pending for a week";
      description = "The hypervisor misses a week of security fixes. `./init.nu <proxmox ip> --upgrade` upgrades it; reboot the host if it says so.";
    };
    machine_check = {
      title = "Machine check errors";
      category = "offline";
      # the kernel's hardware error lines of the current boot (pve-install.nu), so it lasts until the next boot
      expr = "max by (vm) (homelab_mce_events_total)";
      threshold = 0;
      for = "0m";
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.vm }}: {{ printf \"%.0f\" $values.A.Value }} machine check errors since boot";
      description = "The cpu or memory reported a hardware error, the usual warning before a hang. `journalctl -k -b --grep 'Hardware Error'` on the host; run memtest and check the cpu's cooling.";
    };
  };

  router = {
    forward_refused = {
      title = "Zone crossing refused";
      category = "attack";
      # the router counts what it drops between the networks by source (300-router forward-deny); the dmz and the
      # apps zone reach nothing private but their forwards, so a refusal there is a missing flow or a guest probing
      expr = "sum by (network) (increase(homelab_forward_denied_packets_total{network=~\"external|apps\"}[1h]))";
      threshold = 0;
      for = "0m";
      summary = "the router refused {{ printf \"%.0f\" $values.A.Value }} packets from the {{ $labels.network }} zone in the last hour";
      description = "A guest of that zone tried to reach the house, the internal zone or another zone without a flow. `journalctl -k --grep fwd-deny` on the router names the source and the destination.";
    };
  };

  monitoring = {
    # dead man's switch: always firing, vm-201 alerts when it stops arriving on the heartbeat topic
    watchdog = {
      title = "Watchdog";
      category = "heartbeat";
      expr = "up{job=\"prometheus\"}";
      threshold = 0;
      for = "0m";
      # prometheus not answering resolves it, which stops the heartbeat
      execErr = "OK";
      summary = "vm-103 evaluates rules and delivers notifications";
      description = "Always firing on purpose. Its absence on ntfy topic ${ntfy.topics.heartbeat} is the alert.";
    };
    monitoring_unit_down = {
      title = "Monitoring unit down";
      category = "monitoring";
      expr = "node_systemd_unit_state{state=\"active\",name=~\"${monitoringUnitsRegex}\"}";
      op = "lt";
      threshold = 1;
      severity = "critical";
      telegram = true;
      summary = "{{ $labels.name }} on vm-103 is not active";
      description = "A part of the metrics, logs or alerting pipeline stopped; alerts that need it cannot fire. `systemctl status {{ $labels.name }}` on vm-103.";
    };
    logs_not_arriving = {
      title = "No logs arriving";
      category = "monitoring";
      expr = "sum(rate(loki_distributor_lines_received_total[15m]))";
      op = "lt";
      threshold = logLinesMinPerSecond;
      for = "15m";
      noData = "Alerting";
      severity = "critical";
      telegram = true;
      summary = "Loki has received no log lines for 15 minutes";
      description = "journal-remote, promtail or loki on vm-103 stopped forwarding; the log alerts see nothing. `journalctl -u promtail -u systemd-journal-remote` on vm-103.";
    };
    # telegram and ntfy (the only webhook) are outside this guest: one alert per channel that keeps failing, through
    # every 10 minutes for a quarter hour (one retried failure is no outage); it reaches the owner over the other one.
    # A channel whose service is down (src/modules/upstream/lib/upstreams.nix) is upstream_unavailable's alert, not a second one
    notifications_failing = {
      title = "Notification channel unavailable";
      category = "monitoring";
      expr =
        "label_replace(sum by (integration) (increase(grafana_alerting_notifications_failed_total[10m])), \"integration\", \"ntfy\", \"integration\", \"webhook\")"
        + " unless on (integration) label_replace(probe_success{job=\"${upstreamJob}\"} == 0, \"integration\", \"$1\", \"upstream\", \"(.+)\")";
      threshold = 0;
      for = "15m";
      telegram = true;
      summary = "{{ $labels.integration }} unavailable: {{ printf \"%.0f\" $values.A.Value }} notifications failed in 10 minutes";
      description = "Grafana cannot deliver to this channel and retries each notification; alerts reach the owner over the other one meanwhile. `journalctl -u grafana | grep -i notify` on vm-103.";
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

  logins = {
    ssh_login_unexpected = {
      title = "Unexpected ssh login";
      category = "attack";
      datasource = "loki";
      expr = "sum by (host, user, source, method) (count_over_time({job=\"systemd-journal\"} |= \"Accepted \" | regexp \"${sshAcceptedPattern}\" | method = \"password\" or (${operatorSourceFilter}) [10m]))";
      threshold = 0;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.user }} logged in to {{ $labels.host }} from {{ $labels.source }} by {{ $labels.method }}";
      description = "An ssh login from outside the operators' addresses (the workstation, the notebook, wireguard, the operator guest, the router) or by password. If nobody here did it, take the guest off the network and rotate the key that let it in.";
    };
    proxmox_login = {
      title = "Proxmox login";
      category = "attack";
      datasource = "loki";
      # api tokens log nothing: this is a person at the web ui or the api's ticket endpoint
      expr = "sum by (host, user) (count_over_time({job=\"systemd-journal\", unit=\"pvedaemon.service\"} |= \"successful auth for user\" | regexp \"successful auth for user '(?P<user>[^']+)'\" [10m]))";
      threshold = 0;
      for = "0m";
      telegram = true;
      summary = "{{ $labels.user }} logged in to Proxmox";
      description = "Someone holds the hypervisor's root. If it was not you, change the password and look at `journalctl -u pvedaemon` on the host.";
    };
  };

  # every service's record (catalog.services): the same rules for a nixos guest's routes and an app's
  serviceRules =
    lib.optionalAttrs (exporterJobs != [ ]) {
      app_target_down = {
        title = "Service metrics unreachable";
        category = "service";
        # an app asleep (idle) or a guest that is down has no exporter to reach; the guest is the offline alert's
        expr = "up{job=~\"${regexOf exporterJobs}\"} unless on (app) homelab_app_idle_stopped == 1 and on (vm) (${guestUp})";
        op = "lt";
        threshold = 1;
        severity = "critical";
        telegram = true;
        summary = "{{ $labels.job }} on {{ $labels.vm }} does not answer";
        description = "Prometheus has not reached this exporter for 5 minutes: the service is down, crash looping or not published.";
      };
    }
    // lib.optionalAttrs (alerted != { }) {
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
        expr =
          "histogram_quantile(0.95, sum by (service, le) (rate(traefik_service_request_duration_seconds_bucket{${traefikSelector alerted}}[${traefikRateWindow}])))"
          + " and on (service) ${busy}";
        threshold = appLatencySeconds;
        for = "15m";
        summary = "{{ $labels.service }}: 95% of requests take up to {{ printf \"%.1f\" $values.A.Value }}s";
        description = "The route's p95 latency at its ingress is above ${toString appLatencySeconds}s. Its board shows whether it is cpu-throttled, out of memory or waiting on a store.";
      };
    }
    // lib.optionalAttrs (alertedApps != [ ]) {
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
      app_builder_stalled = {
        title = "App builder stalled";
        category = "apps";
        expr = "time() - max(homelab_app_builder_last_run_timestamp_seconds{vm=\"${builder}\"})";
        threshold = builderStaleSeconds;
        for = "0m";
        telegram = true;
        summary = "the app builder on ${builder} has not looked at every app for {{ humanizeDuration $values.A.Value }}";
        description = "A run hangs or the builder's timer stopped: no commit deploys. `systemctl status app-builder` and `journalctl -u app-builder` on ${builder}.";
      };
      app_deploy_failed = {
        title = "App deploy failed";
        category = "apps";
        # only the builder's own file: another guest's stale one must not outvote it
        expr = "min by (app) (homelab_app_deploy_ok{vm=\"${builder}\",app=~\"${regexOf alertedApps}\"})";
        op = "lt";
        threshold = 1;
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
        op = "lt";
        threshold = 1;
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
        op = "lt";
        threshold = 1;
        severity = "critical";
        telegram = true;
        summary = "{{ $labels.service }}: no node answers its health check";
        description = "The edge's health check fails on every node of the app's cluster: the app is down for its users. `docker service ps <app>_<service>` on its manager.";
      };
      app_memory_saturated = {
        title = "App task near its memory limit";
        category = "apps";
        expr =
          let
            tasks = "swarm_stack=~\"${regexOf alertedApps}\"";
          in
          "100 * max by (swarm_service) (container_memory_working_set_bytes{${tasks}} / (container_spec_memory_limit_bytes{${tasks}} > 0))";
        threshold = appSaturationPercent;
        for = "15m";
        summary = "{{ $labels.swarm_service }}: {{ printf \"%.0f\" $values.A.Value }}% of its memory limit";
        description = "The task reclaims and will be killed inside its own limit. Raise apps.<app>.resources.<service>.memoryMiB (and its reservation) or fix the leak.";
      };
    }
    // lib.optionalAttrs (appsWithMetric "postgres" != { }) {
      app_postgres_down = {
        title = "App database down";
        category = "apps";
        expr = "min by (app) (pg_up)";
        op = "lt";
        threshold = 1;
        severity = "critical";
        telegram = true;
        summary = "{{ $labels.app }}: postgres down";
        description = "postgres_exporter answers but cannot reach postgres. Check the stack's postgres service on its nodes.";
      };
    }
    // lib.optionalAttrs (appsWithMetric "redis" != { }) {
      app_redis_down = {
        title = "App cache down";
        category = "apps";
        expr = "min by (app) (redis_up)";
        op = "lt";
        threshold = 1;
        severity = "critical";
        telegram = true;
        summary = "{{ $labels.app }}: redis down";
        description = "redis_exporter answers but cannot reach redis. Check the stack's redis service on its nodes.";
      };
    };
in
guests // host // router // monitoring // logins // serviceRules
