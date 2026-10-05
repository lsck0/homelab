---
name: monitoring
description: Metrics, logs, alerts, uptime and dashboards.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Grafana, Prometheus, Loki]
    related_skills: [homelab-ops]
---

# Monitoring (vm-105 10.100.0.105)

- Prometheus `http://10.100.0.105:9090`: node-exporter on every VM (:9100), Traefik (:8082),
  itself (job `prometheus`, `prometheus_tsdb_storage_blocks_bytes`; capped at 50GB).
  Swarm apps (`src/modules/apps.nix`, enabled ones only): jobs `app-<app>-<name>` every 15s,
  label `app`, scraped on the first apps node; `app-cadvisor` on every apps node with
  `swarm_service`/`swarm_stack` labels (`container_*` by `name=~"<app>_.*"`).
  Query: `curl -sG http://10.100.0.105:9090/api/v1/query --data-urlencode 'query=up == 0'`.
  Useful: `100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100`,
  `node_filesystem_avail_bytes{mountpoint="/"}`, `node_memory_MemAvailable_bytes`,
  `time() - homelab_backup_last_success_timestamp_seconds` (backup age).
- Loki `http://10.100.0.105:3100`: journal of every VM (label `host="vm-<id>"`, `unit`),
  Traefik access logs (`job="traefik-access"`, labels country/status).
  Container logs carry `container_name`; swarm tasks also `swarm_service` (`<stack>_<service>`)
  and `swarm_stack`: `{swarm_stack="wat"}`, `{swarm_service="wat_server"} | json`.
  `curl -sG http://10.100.0.105:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-121"} |= "error"' --data-urlencode limit=100 --data-urlencode since=1h`
- Alerting is Grafana unified alerting only; there is no Alertmanager. It used
  to run alongside Grafana with the same rule and the same receivers, which
  delivered every alert twice. Rules, contact points and the notification
  policy are provisioned in `src/instances/105-internal-grafana.nix`.
  Firing alerts: `curl -s -H 'Remote-User: hermes' http://10.100.0.105/api/alertmanager/grafana/api/v2/alerts`.
  Silence: `POST /api/alertmanager/grafana/api/v2/silences` with matchers, startsAt, endsAt, createdBy, comment.
- Grafana https://grafana.lsck0.dev (dashboard "Homelab"); API from the VM on port 80 needs the auth proxy header:
  `ssh 10.100.0.105 curl -s -H 'Remote-User: hermes' localhost/api/search`.
- Tempo (traces) OTLP at 10.100.0.105:4317/4318; its span metrics (`traces_spanmetrics_*`,
  `traces_service_graph_*`) land in Prometheus.
- Pyroscope (profiles) at 10.100.0.105:4040, Grafana datasource uid `pyroscope`, 14 days.
- App boards: one per enabled webapp-template stack, uid `app-<app>` (e.g. `app-wat`).
- App alerts: `app_target_down`, `app_postgres_down`, `app_redis_down`, `app_5xx`,
  `app_restart_loop`, `app_<app>_walg_stale`. Disk: `disk_full` (90%, every ext4 data fs),
  `disk_critical` (95%, telegram), `disk_fill_predicted`, `thinpool_*` (Proxmox thin pool).

When the owner asks "is everything ok": query `up == 0`, active alerts, disk
space below 10 %, backup age, then summarise in a few lines.
