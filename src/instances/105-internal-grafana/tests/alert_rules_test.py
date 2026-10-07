"""The provisioned Grafana alert rules (105-internal-grafana.nix) as Prometheus rules, for promtool.

Usage: alert_rules_test.py <rules.json> <app> <builder> <out dir>

<app>: an app the catalog enables; <builder>: the `vm` label of the app builder's guest.

Writes <out dir>/rules.json, every Prometheus-backed Grafana rule as an alerting rule with the same expression,
threshold, `for` and labels (Loki rules stay out: promtool evaluates PromQL only), and <out dir>/tests.json, the
cases below in promtool's unit test format. tests/alert-rules.nix runs `promtool check rules` and `promtool test
rules` on them.

The cases are the policy, written out as an oracle: which series make which rule fire with which labels, and which
must stay quiet (an idle guest asleep, a service on a guest that is down, a 5xx share at noise traffic, a dump
stale only because its guest just woke up, a stale deploy metric on a guest that is no builder, a manager failure the
builder already reports).
"""
import json
import os
import sys

RULES, APP, BUILDER, OUT = sys.argv[1:5]
OPERATORS = {"gt": ">", "lt": "<"}
NODE = 'job="homelab-node-exporter"'
EDGE = "10.200.0.200:8082"
INTERNAL = "10.100.0.100:8082"
# a nixos guest's route, on the internal ingress
GUEST_ROUTE = "jellyfin@file"


def prometheus_rule(rule):
    """One grafana rule (query A, threshold C) as a prometheus alerting rule; None for a loki rule."""
    query = next(d for d in rule["data"] if d["refId"] == "A")
    if query["datasourceUid"] != "prometheus":
        return None
    evaluator = next(d for d in rule["data"] if d["refId"] == "C")["model"]["conditions"][0]["evaluator"]
    return {
        "alert": rule["uid"],
        "expr": f"({query['model']['expr']}) {OPERATORS[evaluator['type']]} {evaluator['params'][0]}",
        "for": rule["for"],
        "labels": rule["labels"],
    }


def labels(rule_labels, **series):
    return dict(rule_labels, **series)


with open(RULES) as handle:
    groups = json.load(handle)
rules = [r for g in groups for r in g["rules"]]
translated = [p for p in map(prometheus_rule, rules) if p]
rule_labels = {r["uid"]: r["labels"] for r in rules}
with open(os.path.join(OUT, "rules.json"), "w") as handle:
    json.dump({"groups": [{"name": "homelab", "interval": "1m", "rules": translated}]}, handle, indent=2)

CRITICAL_PAGE = {"severity": "critical", "notify": "telegram"}
WARNING_PAGE = {"severity": "warning", "notify": "telegram"}


def expect(uid, **series):
    return {"exp_labels": labels(rule_labels[uid], **series)}


paperless = {"instance": "10.100.0.121:9100", "vm": "paperless"}
nas = {"instance": "10.100.0.109:9100", "vm": "nas"}
# idle: the scrape labels a guest that sleeps on purpose
archbuild = {"instance": "10.100.0.119:9100", "vm": "archbuild", "idle": "true"}
# the app's routes as the edge names its services (catalog.nix): the app itself and a path of it
app_root = f"{APP}@file"
app_api = f"{APP}-api@file"
app_server = f"{APP}_server"

tests = [
    {
        "name": "guests: an enabled guest down pages, an idle one asleep does not; a service on a down guest is "
                "the guest's alert",
        "interval": "1m",
        "input_series": [
            {"series": f'up{{{NODE},instance="{paperless["instance"]}",vm="paperless"}}', "values": "1x20"},
            {"series": f'up{{{NODE},instance="{nas["instance"]}",vm="nas"}}', "values": "0x20"},
            {"series": f'up{{{NODE},instance="{archbuild["instance"]}",vm="archbuild",idle="true"}}', "values": "0x20"},
            {"series": 'probe_success{job="blackbox-http",service="paperless",vm="paperless"}', "values": "0x20"},
            {"series": 'probe_success{job="blackbox-http",service="nas",vm="nas"}', "values": "0x20"},
        ],
        "alert_rule_test": [
            {"eval_time": "4m", "alertname": "instance_down", "exp_alerts": []},
            {"eval_time": "6m", "alertname": "instance_down", "exp_alerts": [expect("instance_down", job="homelab-node-exporter", **nas)]},
            {"eval_time": "9m", "alertname": "service_down", "exp_alerts": []},
            {"eval_time": "11m", "alertname": "service_down",
             "exp_alerts": [expect("service_down", job="blackbox-http", service="paperless", vm="paperless")]},
        ],
    },
    {
        "name": "services: 5xx pages above the share at real traffic only, a guest's route like an app's; a failed deploy and a restart loop are reported",
        "interval": "1m",
        "input_series": [
            {"series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_root}",code="200"}}', "values": "0+60x20"},
            {"series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_root}",code="500"}}', "values": "0+60x20"},
            {"series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_api}",code="500"}}', "values": "0+3x20"},
            {"series": f'traefik_service_requests_total{{instance="{INTERNAL}",service="{GUEST_ROUTE}",code="500"}}', "values": "0+60x20"},
            {"series": f'homelab_app_deploy_ok{{app="{APP}",vm="{BUILDER}"}}', "values": "1 1 0x10"},
            # the builder's old guest kept its last file: it must not page, nor outvote the builder
            {"series": f'homelab_app_deploy_ok{{app="{APP}",vm="github-runner"}}', "values": "0x15"},
            # the manager failed the same deploy: the builder's alert is the page
            {"series": f'homelab_swarm_deploy_ok{{app="{APP}",vm="swarm-internal"}}', "values": "1 1 0x10"},
            {"series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.a"}}', "values": "1 1 1 _x10"},
            {"series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.b"}}', "values": "_ _ 1 1 _x10"},
            {"series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.c"}}', "values": "_ _ _ 1 1 _x10"},
            {"series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.d"}}', "values": "_ _ _ _ 1 1x10"},
            {"series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{APP}_db",name="{APP}_db.1.a"}}', "values": "1x15"},
        ],
        "alert_rule_test": [
            {"eval_time": "9m", "alertname": "app_5xx", "exp_alerts": []},
            {"eval_time": "16m", "alertname": "app_5xx",
             "exp_alerts": [expect("app_5xx", service=app_root), expect("app_5xx", service=GUEST_ROUTE)]},
            {"eval_time": "1m", "alertname": "app_deploy_failed", "exp_alerts": []},
            {"eval_time": "3m", "alertname": "app_deploy_failed", "exp_alerts": [expect("app_deploy_failed", app=APP)]},
            {"eval_time": "3m", "alertname": "app_swarm_deploy_failed", "exp_alerts": []},
            {"eval_time": "6m", "alertname": "app_restart_loop", "exp_alerts": [expect("app_restart_loop", swarm_service=app_server)]},
        ],
    },
    {
        "name": "backups: a dump goes stale only once its guest has been up for the catch-up hour",
        "interval": "5m",
        "input_series": [
            {"series": 'homelab_db_dump_last_success_timestamp_seconds{vm="paperless",db="paperless"}', "values": "0x400"},
            {"series": f'up{{{NODE},instance="{paperless["instance"]}",vm="paperless"}}', "values": "0x330 1x70"},
            {"series": 'homelab_backup_last_success_timestamp_seconds{type="daily"}', "values": "0x400"},
        ],
        "alert_rule_test": [
            {"eval_time": "1675m", "alertname": "db_dump_stale", "exp_alerts": []},
            {"eval_time": "1720m", "alertname": "db_dump_stale", "exp_alerts": [expect("db_dump_stale", vm="paperless", db="paperless")]},
            {"eval_time": "1580m", "alertname": "backup_stale", "exp_alerts": []},
            {"eval_time": "1600m", "alertname": "backup_stale", "exp_alerts": [expect("backup_stale")]},
        ],
    },
    {
        "name": "builds: the arch repo's last nightly value counts all day while vm-119 sleeps, a day later it is gone",
        "interval": "1h",
        "input_series": [
            {"series": f'homelab_archrepo_missing_packages{{{NODE},vm="archbuild"}}', "values": "_x3 2 _x30"},
            {"series": f'homelab_archrepo_held_back{{{NODE},vm="archbuild"}}', "values": "_x3 0 _x30"},
        ],
        "alert_rule_test": [
            {"eval_time": "20h", "alertname": "archrepo_missing",
             "exp_alerts": [expect("archrepo_missing", job="homelab-node-exporter", vm="archbuild")]},
            {"eval_time": "31h", "alertname": "archrepo_missing", "exp_alerts": []},
            {"eval_time": "20h", "alertname": "archrepo_held_back", "exp_alerts": []},
        ],
    },
    {
        "name": "storage: a linear decline is forecast, every thin pool names its volume group",
        "interval": "1m",
        "input_series": [
            {"series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/data",vm="nas"}', "values": "100000000000-10000000x200"},
            {"series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/",vm="nas"}', "values": "100000000000x200"},
            {"series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/data",vm="nas"}', "values": "1000000000000x200"},
            {"series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/",vm="nas"}', "values": "1000000000000x200"},
            {"series": 'homelab_thinpool_data_percent{vm="proxmox",vg="bulk"}', "values": "85x40"},
            {"series": 'homelab_thinpool_data_percent{vm="proxmox",vg="pve"}', "values": "40x40"},
        ],
        "alert_rule_test": [
            {"eval_time": "100m", "alertname": "disk_fill_predicted", "exp_alerts": []},
            {"eval_time": "125m", "alertname": "disk_fill_predicted",
             "exp_alerts": [expect("disk_fill_predicted", fstype="ext4", mountpoint="/data", vm="nas")]},
            {"eval_time": "35m", "alertname": "thinpool_data_warn", "exp_alerts": [expect("thinpool_data_warn", vm="proxmox", vg="bulk")]},
        ],
    },
    {
        "name": "monitoring: the watchdog always fires, a stopped unit and a silent loki page",
        "interval": "1m",
        "input_series": [
            {"series": 'up{job="prometheus",instance="127.0.0.1:9091"}', "values": "1x30"},
            {"series": 'node_systemd_unit_state{name="loki.service",state="active",vm="grafana"}', "values": "1 1 0x20"},
            {"series": 'node_systemd_unit_state{name="grafana.service",state="active",vm="grafana"}', "values": "1x22"},
            {"series": 'loki_distributor_lines_received_total{component="loki"}', "values": "0+600x10 6000x30"},
        ],
        "alert_rule_test": [
            {"eval_time": "1m", "alertname": "watchdog", "exp_alerts": [expect("watchdog", job="prometheus", instance="127.0.0.1:9091")]},
            {"eval_time": "8m", "alertname": "monitoring_unit_down",
             "exp_alerts": [expect("monitoring_unit_down", name="loki.service", state="active", vm="grafana")]},
            {"eval_time": "20m", "alertname": "logs_not_arriving", "exp_alerts": []},
            {"eval_time": "40m", "alertname": "logs_not_arriving", "exp_alerts": [expect("logs_not_arriving")]},
        ],
    },
]

tests += [
    {
        "name": "deploys: a manager that fails a deploy the builder got through pages, naming the manager",
        "interval": "1m",
        "input_series": [
            {"series": f'homelab_app_deploy_ok{{app="{APP}",vm="{BUILDER}"}}', "values": "1x10"},
            {"series": f'homelab_swarm_deploy_ok{{app="{APP}",vm="swarm-internal"}}', "values": "1 0x9"},
        ],
        "alert_rule_test": [
            {"eval_time": "3m", "alertname": "app_swarm_deploy_failed",
             "exp_alerts": [expect("app_swarm_deploy_failed", app=APP, vm="swarm-internal")]},
            {"eval_time": "3m", "alertname": "app_deploy_failed", "exp_alerts": []},
        ],
    },
    {
        "name": "hardware: a thrashing guest, an nvme warning and a hot nvme page; a busy but healthy guest does not",
        "interval": "1m",
        "input_series": [
            {"series": 'node_pressure_memory_stalled_seconds_total{vm="traefik-internal"}', "values": "0+30x30"},
            {"series": 'node_pressure_memory_stalled_seconds_total{vm="nas"}', "values": "0+1x30"},
            {"series": 'nvme_critical_warning{vm="proxmox",device="nvme1n1"}', "values": "0 0 4x10"},
            {"series": 'nvme_temperature_celsius{vm="proxmox",device="nvme1n1"}', "values": "75x30"},
            {"series": 'nvme_temperature_celsius{vm="proxmox",device="nvme0n1"}', "values": "40x30"},
        ],
        "alert_rule_test": [
            {"eval_time": "20m", "alertname": "memory_pressure", "exp_alerts": [expect("memory_pressure", vm="traefik-internal")]},
            {"eval_time": "3m", "alertname": "nvme_critical_warning",
             "exp_alerts": [expect("nvme_critical_warning", vm="proxmox", device="nvme1n1")]},
            {"eval_time": "20m", "alertname": "nvme_temperature",
             "exp_alerts": [expect("nvme_temperature", vm="proxmox", device="nvme1n1")]},
        ],
    },
    {
        "name": "idle: a wake that never answered and an api the ingress cannot reach page",
        "interval": "1m",
        "input_series": [
            {"series": 'homelab_ondemand_wake_ok{vm="traefik-internal",service="archbuild",target="vm-119"}', "values": "1 0x5"},
            {"series": 'homelab_ondemand_wake_ok{vm="traefik-internal",service="paperless",target="vm-121"}', "values": "1x6"},
            {"series": 'homelab_ondemand_api_ok{vm="traefik-external"}', "values": "0x20"},
        ],
        "alert_rule_test": [
            {"eval_time": "2m", "alertname": "ondemand_wake_failed",
             "exp_alerts": [expect("ondemand_wake_failed", vm="traefik-internal", target="vm-119")]},
            {"eval_time": "10m", "alertname": "ondemand_api_failing", "exp_alerts": []},
            {"eval_time": "16m", "alertname": "ondemand_api_failing", "exp_alerts": [expect("ondemand_api_failing", vm="traefik-external")]},
        ],
    },
    {
        "name": "alert path: a channel that keeps failing is named once, a single retried failure is not",
        "interval": "1m",
        "input_series": [
            {"series": 'grafana_alerting_notifications_failed_total{integration="webhook",component="grafana"}', "values": "0+1x40"},
            {"series": 'grafana_alerting_notifications_failed_total{integration="telegram",component="grafana"}', "values": "0 1x40"},
        ],
        "alert_rule_test": [
            {"eval_time": "10m", "alertname": "notifications_failing", "exp_alerts": []},
            {"eval_time": "20m", "alertname": "notifications_failing",
             "exp_alerts": [expect("notifications_failing", integration="ntfy")]},
            {"eval_time": "40m", "alertname": "notifications_failing",
             "exp_alerts": [expect("notifications_failing", integration="ntfy")]},
        ],
    },
    {
        "name": "disks: a smartd warning pages while smartd repeats it, and ends a day after the last one",
        "interval": "1h",
        "input_series": [
            {"series": 'homelab_smartd_warning_timestamp_seconds{vm="proxmox",device="/dev/nvme1",type="Temperature"}', "values": "0x40"},
        ],
        "alert_rule_test": [
            {"eval_time": "1h", "alertname": "smartd_warning",
             "exp_alerts": [expect("smartd_warning", vm="proxmox", device="/dev/nvme1", type="Temperature")]},
            {"eval_time": "27h", "alertname": "smartd_warning", "exp_alerts": []},
        ],
    },
]

# the oracle's own premises: the rules it tests exist, and their paging is what the policy says
for uid, page in (("instance_down", CRITICAL_PAGE), ("service_down", CRITICAL_PAGE), ("backup_stale", CRITICAL_PAGE),
                  ("app_5xx", WARNING_PAGE), ("monitoring_unit_down", CRITICAL_PAGE)):
    assert {k: rule_labels[uid].get(k) for k in page} == page, (uid, rule_labels[uid])
assert "notify" not in rule_labels["watchdog"] and rule_labels["watchdog"]["category"] == "heartbeat"
assert "notify" not in rule_labels["disk_fill_predicted"], "a forecast never pages"

with open(os.path.join(OUT, "tests.json"), "w") as handle:
    json.dump({"rule_files": ["rules.json"], "evaluation_interval": "1m", "tests": tests}, handle, indent=2)
print(f"{len(translated)} of {len(rules)} rules translated, {len(tests)} cases")
