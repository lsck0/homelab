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

# Monitoring (vm-104 10.100.0.104, vm-105 10.100.0.105)

- Prometheus `http://10.100.0.104:9090`: node-exporter on every VM (:9100), Traefik (:8082).
  Query: `curl -sG http://10.100.0.104:9090/api/v1/query --data-urlencode 'query=up == 0'`.
  Useful: `100 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100`,
  `node_filesystem_avail_bytes{mountpoint="/"}`, `node_memory_MemAvailable_bytes`,
  `time() - homelab_backup_last_success_timestamp_seconds` (backup age).
- Loki `http://10.100.0.104:3100`: journal of every VM (label `host="vm-<id>"`, `unit`),
  Traefik access logs (`job="traefik-access"`, labels country/status).
  `curl -sG http://10.100.0.104:3100/loki/api/v1/query_range --data-urlencode 'query={host="vm-120"} |= "error"' --data-urlencode limit=100 --data-urlencode since=1h`
- Alertmanager `http://10.100.0.104:9093/api/v2/alerts` -> ntfy topic (see `notifications`).
  Silence: `POST /api/v2/silences` with matchers, startsAt, endsAt, createdBy, comment.
- Grafana https://grafana.lsck0.dev (dashboard "Homelab"); API from the VM on port 80 needs the auth proxy header:
  `ssh 10.100.0.104 curl -s -H 'Remote-User: hermes' localhost/api/search`.
- Uptime Kuma https://status.lsck0.dev: HTTP monitors for every always-on service.
- Tempo (traces) OTLP at 10.100.0.104:4317/4318.

When the owner asks "is everything ok": query `up == 0`, active alerts, disk
space below 10 %, backup age, then summarise in a few lines.
