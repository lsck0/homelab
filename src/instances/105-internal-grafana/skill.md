---
name: grafana
description: Metrics, logs, alerts, uptime and dashboards.
version: 1.1.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Grafana, Prometheus, Loki]
    related_skills: [homelab-ops]
---

# Monitoring (vm-105 10.100.0.105)

Ports and addresses are defined once in `src/modules/telemetry.nix`; rules, contact points and scrape jobs in
`src/instances/105-internal-grafana/main.nix`.

- Prometheus `http://10.100.0.105:9090` is read-only from other hosts (GET, and POST on the query endpoints);
  writes (remote write, admin api) only reach it on vm-105's loopback.
  node-exporter on every VM (:9100, label `vm`), Traefik (:8082), the monitoring stack itself (job `monitoring`,
  label `component`: loki, tempo, pyroscope, grafana, promtail), itself (job `prometheus`; capped at 50GB).
  Swarm apps (`src/apps/<app>/app.nix`, enabled ones only): one job per exporter `app-<app>-<name>` every 15s,
  label `app`, at most 10000 samples a scrape (above, that scrape fails alone: `up` 0,
  `prometheus_target_scrapes_exceeded_sample_limit_total`); `app-cadvisor` on every apps node with
  `swarm_service`/`swarm_stack` labels (`container_*` by `swarm_stack="<app>"`); `app-logs`, the workers' log
  shippers (`logentry_dropped_lines_by_label_total{label_value="<app>"}`: lines above an app's budget).
  Query: `curl -sG http://10.100.0.105:9090/api/v1/query --data-urlencode 'query=up == 0'`.
  Useful: `100 - avg by(vm)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100`,
  `node_filesystem_avail_bytes{mountpoint="/"}`, `node_memory_MemAvailable_bytes`,
  `time() - homelab_backup_last_success_timestamp_seconds` (backup age),
  `homelab_app_deploy_ok` (1 if an app's last build and deploy on vm-140 worked).
- Loki `http://10.100.0.105:3100`, one tenant per app plus the lab's: a request without `X-Scope-OrgID` is the
  lab's (tenant `fake`, the name loki stored everything under before it had tenants): journal of every VM (label
  `host="vm-<id>"`, `unit`), Traefik access logs (`job="traefik-access"`, labels country/status). An app's container lines are in tenant `app-<app>`
  (labels `container_name`, `swarm_service` = `<app>_<service>`, `swarm_stack`, `stream`), 100 lines/s each,
  longer lines cut at 16 KiB; several tenants at once: `app-wat|fake`.
  `curl -sG http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-121"} |= "error"' --data-urlencode limit=100 --data-urlencode since=1h`
  `curl -sG -H 'X-Scope-OrgID: app-wat' http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={swarm_service="wat_server"} | json' --data-urlencode since=1h`
- Grafana https://grafana.lsck0.dev: boards "Homelab", "Energie", "Services" (every service, nixos or app:
  deployed, asleep, requests, 5xx, p95, memory, telemetry volume, a click to its board), a folder per app with its
  board `service-<app>` (deploys, resources per service and task, routes and refusals at the edge, tcp/udp
  forwards, logs, traces, profiles, frontend, scrapes) plus the boards the app ships (`<app>-<uid>`, from its repo
  at deploy), and the folder "Lab services" with the same board for every nixos service (its guest's resources and
  journal). A service opts out with `off.dashboard`, `off.alerts`, `off.metrics`. It takes the `Remote-User` header
  only from the ingress and from vm-105 itself, so its API is called on vm-105:
  `ssh 10.100.0.105 curl -s -H 'Remote-User: hermes' localhost/api/search`.
- Alerting is Grafana unified alerting only; there is no Alertmanager. It used
  to run alongside Grafana with the same rule and the same receivers, which
  delivered every alert twice. Notifications are grouped by the `category` label
  (offline, service, backups, attack, storage, apps, monitoring): one message per
  category with one line per alert, to ntfy topic `homelab-alerts`, and to Telegram
  for rules labeled `notify=telegram`.
  Firing alerts: `ssh 10.100.0.105 curl -s -H 'Remote-User: hermes' localhost/api/alertmanager/grafana/api/v2/alerts`.
  Silence: `POST localhost/api/alertmanager/grafana/api/v2/silences` (same way) with matchers, startsAt, endsAt,
  createdBy, comment.
- The `watchdog` rule fires on purpose, always: it posts to ntfy topic `homelab-heartbeat` every 5 minutes, and
  vm-203 alerts on `homelab-alerts` when that stops (vm-105 down, alerting stalled, Prometheus down). Never
  silence it.
- Tempo (traces) OTLP at 10.100.0.105:4317/4318 and Pyroscope (profiles) at :4040, 14 days, one tenant per app:
  every request carries `X-Scope-OrgID: app-<app>` (the swarm injects it into the app's containers as
  `OTEL_EXPORTER_OTLP_HEADERS`), each tenant 1 MiB/s (burst 4 MiB) of each; above that, 429 for that app alone.
  Datasources "Tempo <app>", "Pyroscope <app>", "Loki <app>". Span metrics (`traces_spanmetrics_*`,
  `traces_service_graph_*`, label `tenant`) land in Prometheus.
  Read one trace: `curl -s -H 'X-Scope-OrgID: app-wat' http://10.100.0.105:3200/api/traces/<id>`.
- Browsers: `<host>/otlp/` on each app's own origin reaches the frontend intake (:4319, from the ingresses only),
  which keeps allow-listed attributes (no cookies, query strings or form data) and files them under the app's
  tenant: traces to Tempo, logs to Loki, metrics (label `tenant`) to Prometheus.
- Service alerts, nixos services and apps alike: `app_target_down` (an exporter), `app_slow` (p95 over 2s),
  `app_5xx`. App alerts: `app_unreachable` (no healthy backend at the edge), `app_memory_saturated` (a task at 90% of its limit), `app_restart_loop`, `app_deploy_failed`
  (builder), `app_swarm_deploy_failed` (manager), `app_postgres_down`, `app_redis_down`, `app_<app>_walg_stale`;
  an app asleep (idle) is not down. Builds: `archrepo_missing`, `archrepo_held_back` (vm-119's nightly repo). Disk: `disk_full` (90%, every ext4 data fs),
  `disk_critical` (95%, telegram), `disk_fill_predicted`, `thinpool_*` (Proxmox thin pools, per `vg`),
  `disk_health` and `nvme_wear` (Proxmox SMART and NVMe collectors). Monitoring: `monitoring_unit_down`,
  `logs_not_arriving`, `promtail_dropping`.

When the owner asks "is everything ok": query `up == 0`, active alerts, disk
space below 10 %, backup age, then summarise in a few lines.
