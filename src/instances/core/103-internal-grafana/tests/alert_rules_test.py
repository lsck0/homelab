"""The provisioned Grafana alert rules (103-internal-grafana.nix) as Prometheus rules, for promtool.

Usage: alert_rules_test.py <rules.json> <app> <builder> <guest route> <archbuild ip> <builder ip> <out dir>

<app>: an app the catalog enables; <builder>: the `vm` label of the app builder's guest; <guest route>: a route of a
powered nixos guest's alerted service on the internal ingress; <archbuild ip>, <builder ip>: the guests whose
forced-command ssh logins are expected.

Writes <out dir>/rules.json, every Prometheus-backed Grafana rule as an alerting rule with the same expression,
threshold, `for` and labels (Loki rules stay out: promtool evaluates PromQL only), and <out dir>/tests.json, the
cases below in promtool's unit test format. tests/alert-rules.nix runs `promtool check rules` and `promtool test
rules` on them.

The cases are the policy, written out as an oracle: which series make which rule fire with which labels, and which
must stay quiet (an idle guest asleep, its host port probe while it sleeps, a disk forecast with headroom or from an idle or down guest, a service on a guest that is down, a 5xx share at noise traffic, a dump
stale only because its guest just woke up, a stale deploy metric on a guest that is no builder, a manager failure the
builder already reports).
"""

import ipaddress
import json
import os
import re
import sys

RULES, APP, BUILDER, GUEST, ARCHBUILD_IP, BUILDER_IP, OUT = sys.argv[1:8]
OPERATORS = {"gt": ">", "lt": "<"}
NODE = 'job="homelab-node-exporter"'
EDGE = "10.200.0.200:8082"
INTERNAL = "10.100.0.100:8082"
# a nixos guest's route as the internal ingress names its service
GUEST_ROUTE = f"{GUEST}@file"


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
rule_by_uid = {r["uid"]: r for r in rules}
with open(os.path.join(OUT, "rules.json"), "w") as handle:
    json.dump({"groups": [{"name": "homelab", "interval": "1m", "rules": translated}]}, handle, indent=2)

CRITICAL_PAGE = {"severity": "critical", "notify": "telegram"}
WARNING_PAGE = {"severity": "warning", "notify": "telegram"}


def expect(uid, **series):
    return {"exp_labels": labels(rule_labels[uid], **series)}


paperless = {"instance": "10.100.0.131:9100", "vm": "paperless"}
# smartd's own words for the warning ride along as a label, so the alert says why
SMARTD_NVME1_LABELS = {
    "vm": "proxmox",
    "device": "/dev/nvme1",
    "type": "Health",
    "message": "Device: /dev/nvme1, Critical Warning (0x02): Temperature",
}
SMARTD_NVME1 = ",".join(f'{k}="{v}"' for k, v in SMARTD_NVME1_LABELS.items())
nas = {"instance": "10.100.0.104:9100", "vm": "nas"}
# idle: the scrape labels a guest that sleeps on purpose
archbuild = {"instance": "10.100.0.112:9100", "vm": "archbuild", "idle": "true"}
searxng = {"instance": "10.200.0.211:9100", "vm": "searxng", "idle": "true"}
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
            {
                "eval_time": "6m",
                "alertname": "instance_down",
                "exp_alerts": [expect("instance_down", job="homelab-node-exporter", **nas)],
            },
            {"eval_time": "9m", "alertname": "service_down", "exp_alerts": []},
            {
                "eval_time": "11m",
                "alertname": "service_down",
                "exp_alerts": [expect("service_down", job="blackbox-http", service="paperless", vm="paperless")],
            },
        ],
    },
    {
        "name": "guests: an idle guest's host port pages while it is awake, not while it sleeps",
        "interval": "1m",
        "input_series": [
            {"series": f'up{{{NODE},instance="{searxng["instance"]}",vm="searxng",idle="true"}}', "values": "1x20"},
            {"series": f'up{{{NODE},instance="{archbuild["instance"]}",vm="archbuild",idle="true"}}', "values": "0x20"},
            {"series": 'probe_success{job="blackbox-backend",service="searxng",vm="searxng"}', "values": "0x20"},
            {"series": 'probe_success{job="blackbox-backend",service="archbuild",vm="archbuild"}', "values": "0x20"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "11m",
                "alertname": "service_down",
                "exp_alerts": [expect("service_down", job="blackbox-backend", service="searxng", vm="searxng")],
            },
        ],
    },
    {
        "name": "services: 5xx pages above the share at real traffic only, a guest's route like an app's; a failed deploy and a restart loop are reported",
        "interval": "1m",
        "input_series": [
            {
                "series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_root}",code="200"}}',
                "values": "0+60x20",
            },
            {
                "series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_root}",code="500"}}',
                "values": "0+60x20",
            },
            {
                "series": f'traefik_service_requests_total{{instance="{EDGE}",service="{app_api}",code="500"}}',
                "values": "0+3x20",
            },
            {
                "series": f'traefik_service_requests_total{{instance="{INTERNAL}",service="{GUEST_ROUTE}",code="500"}}',
                "values": "0+60x20",
            },
            {"series": f'homelab_app_deploy_ok{{app="{APP}",vm="{BUILDER}"}}', "values": "1 1 0x10"},
            # the builder's old guest kept its last file: it must not page, nor outvote the builder
            {"series": f'homelab_app_deploy_ok{{app="{APP}",vm="github-runner"}}', "values": "0x15"},
            # the manager failed the same deploy: the builder's alert is the page
            {"series": f'homelab_swarm_deploy_ok{{app="{APP}",vm="swarm-internal"}}', "values": "1 1 0x10"},
            {
                "series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.a"}}',
                "values": "1 1 1 _x10",
            },
            {
                "series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.b"}}',
                "values": "_ _ 1 1 _x10",
            },
            {
                "series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.c"}}',
                "values": "_ _ _ 1 1 _x10",
            },
            {
                "series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{app_server}",name="{app_server}.1.d"}}',
                "values": "_ _ _ _ 1 1x10",
            },
            {
                "series": f'container_start_time_seconds{{swarm_stack="{APP}",swarm_service="{APP}_db",name="{APP}_db.1.a"}}',
                "values": "1x15",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "9m", "alertname": "app_5xx", "exp_alerts": []},
            {
                "eval_time": "16m",
                "alertname": "app_5xx",
                "exp_alerts": [expect("app_5xx", service=app_root), expect("app_5xx", service=GUEST_ROUTE)],
            },
            {"eval_time": "1m", "alertname": "app_deploy_failed", "exp_alerts": []},
            {"eval_time": "3m", "alertname": "app_deploy_failed", "exp_alerts": [expect("app_deploy_failed", app=APP)]},
            {"eval_time": "3m", "alertname": "app_swarm_deploy_failed", "exp_alerts": []},
            {
                "eval_time": "6m",
                "alertname": "app_restart_loop",
                "exp_alerts": [expect("app_restart_loop", swarm_service=app_server)],
            },
        ],
    },
    {
        "name": "backups: a dump goes stale only once its guest has been up for the catch-up hour",
        "interval": "5m",
        "input_series": [
            {
                "series": 'homelab_db_dump_last_success_timestamp_seconds{vm="paperless",db="paperless"}',
                "values": "0x400",
            },
            {"series": f'up{{{NODE},instance="{paperless["instance"]}",vm="paperless"}}', "values": "0x330 1x70"},
            {"series": 'homelab_backup_last_success_timestamp_seconds{type="daily"}', "values": "0x400"},
        ],
        "alert_rule_test": [
            {"eval_time": "1675m", "alertname": "db_dump_stale", "exp_alerts": []},
            {
                "eval_time": "1720m",
                "alertname": "db_dump_stale",
                "exp_alerts": [expect("db_dump_stale", vm="paperless", db="paperless")],
            },
            {"eval_time": "1580m", "alertname": "backup_stale", "exp_alerts": []},
            {"eval_time": "1600m", "alertname": "backup_stale", "exp_alerts": [expect("backup_stale")]},
        ],
    },
    {
        "name": "builds: the arch repo's last nightly value counts all day while vm-112 sleeps, a day later it is gone",
        "interval": "1h",
        "input_series": [
            {"series": f'homelab_archrepo_missing_packages{{{NODE},vm="archbuild"}}', "values": "_x3 2 _x30"},
            {"series": f'homelab_archrepo_held_back{{{NODE},vm="archbuild"}}', "values": "_x3 0 _x30"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "20h",
                "alertname": "archrepo_missing",
                "exp_alerts": [expect("archrepo_missing", job="homelab-node-exporter", vm="archbuild")],
            },
            {"eval_time": "31h", "alertname": "archrepo_missing", "exp_alerts": []},
            {"eval_time": "20h", "alertname": "archrepo_held_back", "exp_alerts": []},
        ],
    },
    {
        "name": "upstream: the router's tor without a circuit for 15 minutes is tor unavailable, back with one",
        "interval": "5m",
        "input_series": [
            {"series": f'homelab_tor_circuit_established{{{NODE},vm="router"}}', "values": "1x3 0x6 1x3"},
        ],
        "alert_rule_test": [
            {"eval_time": "30m", "alertname": "tor_unavailable", "exp_alerts": []},
            {"eval_time": "40m", "alertname": "tor_unavailable", "exp_alerts": [expect("tor_unavailable")]},
            {"eval_time": "65m", "alertname": "tor_unavailable", "exp_alerts": []},
        ],
    },
    {
        "name": "storage: every thin pool names its volume group",
        "interval": "1m",
        "input_series": [
            {"series": 'homelab_thinpool_data_percent{vm="proxmox",vg="bulk"}', "values": "85x40"},
            {"series": 'homelab_thinpool_data_percent{vm="proxmox",vg="pve"}', "values": "40x40"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "35m",
                "alertname": "thinpool_data_warn",
                "exp_alerts": [expect("thinpool_data_warn", vm="proxmox", vg="bulk")],
            },
        ],
    },
    {
        "name": "storage: a sustained decline on a fuller disk is forecast; one with headroom, an idle guest's and a "
        "down guest's stale samples are not",
        "interval": "1m",
        "input_series": [
            # 10% free, 100 megabytes less a minute
            {
                "series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/data",vm="nas"}',
                "values": "100000000000-100000000x400",
            },
            {
                "series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/data",vm="nas"}',
                "values": "1000000000000x400",
            },
            {
                "series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/",vm="nas"}',
                "values": "100000000000x400",
            },
            {
                "series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/",vm="nas"}',
                "values": "1000000000000x400",
            },
            {"series": f'up{{{NODE},vm="nas"}}', "values": "1x400"},
            # the same decline with over half the disk free: a step, not a trend
            {
                "series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/",vm="forgejo"}',
                "values": "180000000000-100000000x400",
            },
            {
                "series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/",vm="forgejo"}',
                "values": "250000000000x400",
            },
            {"series": f'up{{{NODE},vm="forgejo"}}', "values": "1x400"},
            # an idle guest awake for a build
            {
                "series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/",vm="archbuild",idle="true"}',
                "values": "100000000000-100000000x400",
            },
            {
                "series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/",vm="archbuild",idle="true"}',
                "values": "1000000000000x400",
            },
            {"series": f'up{{{NODE},vm="archbuild",idle="true"}}', "values": "1x400"},
            # a guest that went down: its samples stay in the window
            {
                "series": 'node_filesystem_avail_bytes{fstype="ext4",mountpoint="/",vm="paperless"}',
                "values": "100000000000-100000000x20 _x380",
            },
            {
                "series": 'node_filesystem_size_bytes{fstype="ext4",mountpoint="/",vm="paperless"}',
                "values": "1000000000000x20 _x380",
            },
            {"series": f'up{{{NODE},vm="paperless"}}', "values": "1x20 0x380"},
        ],
        "alert_rule_test": [
            {"eval_time": "355m", "alertname": "disk_fill_predicted", "exp_alerts": []},
            {
                "eval_time": "365m",
                "alertname": "disk_fill_predicted",
                "exp_alerts": [expect("disk_fill_predicted", fstype="ext4", mountpoint="/data", vm="nas")],
            },
        ],
    },
    {
        "name": "monitoring: the watchdog always fires, a stopped unit and a silent loki page",
        "interval": "1m",
        "input_series": [
            {"series": 'up{job="prometheus",instance="127.0.0.1:9091"}', "values": "1x30"},
            {
                "series": 'node_systemd_unit_state{name="loki.service",state="active",vm="grafana"}',
                "values": "1 1 0x20",
            },
            {"series": 'node_systemd_unit_state{name="grafana.service",state="active",vm="grafana"}', "values": "1x22"},
            {"series": 'loki_distributor_lines_received_total{component="loki"}', "values": "0+600x10 6000x30"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "1m",
                "alertname": "watchdog",
                "exp_alerts": [expect("watchdog", job="prometheus", instance="127.0.0.1:9091")],
            },
            {
                "eval_time": "8m",
                "alertname": "monitoring_unit_down",
                "exp_alerts": [expect("monitoring_unit_down", name="loki.service", state="active", vm="grafana")],
            },
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
            {
                "eval_time": "3m",
                "alertname": "app_swarm_deploy_failed",
                "exp_alerts": [expect("app_swarm_deploy_failed", app=APP, vm="swarm-internal")],
            },
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
            {
                "eval_time": "20m",
                "alertname": "memory_pressure",
                "exp_alerts": [expect("memory_pressure", vm="traefik-internal")],
            },
            {
                "eval_time": "3m",
                "alertname": "nvme_critical_warning",
                "exp_alerts": [expect("nvme_critical_warning", vm="proxmox", device="nvme1n1")],
            },
            {
                "eval_time": "20m",
                "alertname": "nvme_temperature",
                "exp_alerts": [expect("nvme_temperature", vm="proxmox", device="nvme1n1")],
            },
        ],
    },
    {
        "name": "idle: a wake that never answered and an api the ingress cannot reach page",
        "interval": "1m",
        "input_series": [
            {
                "series": 'homelab_ondemand_wake_ok{vm="traefik-internal",service="archbuild",target="vm-112"}',
                "values": "1 0x5",
            },
            {
                "series": 'homelab_ondemand_wake_ok{vm="traefik-internal",service="paperless",target="vm-131"}',
                "values": "1x6",
            },
            {"series": 'homelab_ondemand_api_ok{vm="traefik-external"}', "values": "0x20"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "2m",
                "alertname": "ondemand_wake_failed",
                "exp_alerts": [expect("ondemand_wake_failed", vm="traefik-internal", target="vm-112")],
            },
            {"eval_time": "10m", "alertname": "ondemand_api_failing", "exp_alerts": []},
            {
                "eval_time": "16m",
                "alertname": "ondemand_api_failing",
                "exp_alerts": [expect("ondemand_api_failing", vm="traefik-external")],
            },
        ],
    },
    {
        "name": "alert path: a channel that keeps failing is named once, a single retried failure is not",
        "interval": "1m",
        "input_series": [
            {
                "series": 'grafana_alerting_notifications_failed_total{integration="webhook",component="grafana"}',
                "values": "0+1x40",
            },
            {
                "series": 'grafana_alerting_notifications_failed_total{integration="telegram",component="grafana"}',
                "values": "0 1x40",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "10m", "alertname": "notifications_failing", "exp_alerts": []},
            {
                "eval_time": "20m",
                "alertname": "notifications_failing",
                "exp_alerts": [expect("notifications_failing", integration="ntfy")],
            },
            {
                "eval_time": "40m",
                "alertname": "notifications_failing",
                "exp_alerts": [expect("notifications_failing", integration="ntfy")],
            },
        ],
    },
    {
        "name": "alert path: telegram's outage is its upstream alert alone, its failed deliveries add none",
        "interval": "1m",
        "input_series": [
            {
                "series": 'grafana_alerting_notifications_failed_total{integration="telegram",component="grafana"}',
                "values": "0+1x40",
            },
            {
                "series": 'probe_success{job="upstream",upstream="telegram",instance="https://api.telegram.org"}',
                "values": "0x40",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "30m", "alertname": "notifications_failing", "exp_alerts": []},
            {
                "eval_time": "30m",
                "alertname": "upstream_unavailable",
                "exp_alerts": [
                    expect(
                        "upstream_unavailable", job="upstream", upstream="telegram", instance="https://api.telegram.org"
                    )
                ],
            },
        ],
    },
    {
        "name": "intrusion detection: ossec down on the host pages after three runs, a running one does not",
        "interval": "5m",
        "input_series": [
            {"series": 'homelab_ossec_up{vm="proxmox"}', "values": "1 1 0 0 0 0 0"},
        ],
        "alert_rule_test": [
            {"eval_time": "15m", "alertname": "ossec_down", "exp_alerts": []},
            {"eval_time": "30m", "alertname": "ossec_down", "exp_alerts": [expect("ossec_down", vm="proxmox")]},
        ],
    },
    {
        "name": "disks: a smartd warning pages while smartd repeats it, and ends a day after the last one",
        "interval": "1h",
        "input_series": [
            {
                "series": f"homelab_smartd_warning_timestamp_seconds{{{SMARTD_NVME1}}}",
                "values": "0x40",
            },
        ],
        "alert_rule_test": [
            {
                "eval_time": "1h",
                "alertname": "smartd_warning",
                "exp_alerts": [expect("smartd_warning", **SMARTD_NVME1_LABELS)],
            },
            {"eval_time": "27h", "alertname": "smartd_warning", "exp_alerts": []},
        ],
    },
    {
        "name": "host: a reboot pages for an hour; an unsafe shutdown pages after an outage longer than its window",
        "interval": "10m",
        "input_series": [
            # booted at 0, rebooted at 29000 s after a hang that silenced the scrapes for five hours
            {"series": f'node_boot_time_seconds{{{NODE},vm="proxmox"}}', "values": "0x19 _x30 29000x20"},
            {"series": 'nvme_unsafe_shutdowns_total{vm="proxmox",device="nvme1n1"}', "values": "111x19 _x30 112x20"},
            {"series": 'nvme_unsafe_shutdowns_total{vm="proxmox",device="nvme0n1"}', "values": "40x19 _x30 40x20"},
        ],
        "alert_rule_test": [
            {"eval_time": "150m", "alertname": "host_rebooted", "exp_alerts": []},
            {"eval_time": "150m", "alertname": "nvme_unsafe_shutdown", "exp_alerts": []},
            {
                "eval_time": "510m",
                "alertname": "host_rebooted",
                "exp_alerts": [expect("host_rebooted", job="homelab-node-exporter", vm="proxmox")],
            },
            {
                "eval_time": "510m",
                "alertname": "nvme_unsafe_shutdown",
                "exp_alerts": [expect("nvme_unsafe_shutdown", vm="proxmox", device="nvme1n1")],
            },
            {"eval_time": "600m", "alertname": "host_rebooted", "exp_alerts": []},
            {"eval_time": "600m", "alertname": "nvme_unsafe_shutdown", "exp_alerts": []},
        ],
    },
    {
        "name": "host: a throttling nvme, a warm one over its warning temperature and machine checks page; a cool drive's"
        " warning minute does not",
        "interval": "5m",
        "input_series": [
            {
                "series": 'homelab_nvme_thermal_throttle_seconds_total{vm="proxmox",device="nvme1n1"}',
                "values": "0+30x20",
            },
            {"series": 'homelab_nvme_thermal_throttle_seconds_total{vm="proxmox",device="nvme0n1"}', "values": "0x20"},
            {
                "series": 'homelab_nvme_warning_temperature_seconds_total{vm="proxmox",device="nvme1n1"}',
                "values": "0x6 60x14",
            },
            # nvme0n1 counts a warning minute at a 38 C composite, as the 980 on firmware 1B4QFXO7 did
            {
                "series": 'homelab_nvme_warning_temperature_seconds_total{vm="proxmox",device="nvme0n1"}',
                "values": "0x6 60x14",
            },
            {"series": 'nvme_temperature_celsius{vm="proxmox",device="nvme1n1"}', "values": "40x6 65x14"},
            {"series": 'nvme_temperature_celsius{vm="proxmox",device="nvme0n1"}', "values": "38x20"},
            {"series": 'homelab_mce_events_total{vm="proxmox"}', "values": "0x4 2x16"},
        ],
        "alert_rule_test": [
            {
                "eval_time": "65m",
                "alertname": "nvme_throttling",
                "exp_alerts": [expect("nvme_throttling", vm="proxmox", device="nvme1n1")],
            },
            {"eval_time": "25m", "alertname": "nvme_over_warning_temperature", "exp_alerts": []},
            {"eval_time": "35m", "alertname": "nvme_over_warning_temperature", "exp_alerts": []},
            {
                "eval_time": "45m",
                "alertname": "nvme_over_warning_temperature",
                "exp_alerts": [expect("nvme_over_warning_temperature", vm="proxmox", device="nvme1n1")],
            },
            {"eval_time": "15m", "alertname": "machine_check", "exp_alerts": []},
            {"eval_time": "25m", "alertname": "machine_check", "exp_alerts": [expect("machine_check", vm="proxmox")]},
        ],
    },
    {
        "name": "guests: a unit failed for a quarter hour, an oom kill and a drifted host alert; healthy guests do not",
        "interval": "1m",
        "input_series": [
            {"series": 'homelab_systemd_failed_units{vm="nas",unit="kopia.service"}', "values": "1x90"},
            {"series": 'node_vmstat_oom_kill{instance="10.100.0.104:9100",vm="nas"}', "values": "0 0 0 1x87"},
            {"series": f'node_vmstat_oom_kill{{instance="{paperless["instance"]}",vm="paperless"}}', "values": "5x90"},
            {"series": 'homelab_system_drift{vm="nas"}', "values": "1x90"},
            {"series": 'homelab_system_drift{vm="paperless"}', "values": "0x90"},
        ],
        "alert_rule_test": [
            {"eval_time": "14m", "alertname": "unit_failed", "exp_alerts": []},
            {
                "eval_time": "16m",
                "alertname": "unit_failed",
                "exp_alerts": [expect("unit_failed", vm="nas", unit="kopia.service")],
            },
            {"eval_time": "2m", "alertname": "oom_kill", "exp_alerts": []},
            {"eval_time": "10m", "alertname": "oom_kill", "exp_alerts": [expect("oom_kill", vm="nas")]},
            {"eval_time": "50m", "alertname": "system_drift", "exp_alerts": []},
            {"eval_time": "70m", "alertname": "system_drift", "exp_alerts": [expect("system_drift", vm="nas")]},
        ],
    },
    {
        "name": "router: a refusal from the dmz alerts, the house's and the internal zone's do not",
        "interval": "1m",
        "input_series": [
            {"series": 'homelab_forward_denied_packets_total{network="external"}', "values": "0 0 0+1x88"},
            {"series": 'homelab_forward_denied_packets_total{network="internal"}', "values": "0+5x90"},
            {"series": 'homelab_forward_denied_packets_total{network="lan"}', "values": "0+5x90"},
        ],
        "alert_rule_test": [
            {"eval_time": "1m", "alertname": "forward_refused", "exp_alerts": []},
            {
                "eval_time": "10m",
                "alertname": "forward_refused",
                "exp_alerts": [expect("forward_refused", network="external")],
            },
        ],
    },
    {
        "name": "host: the softdog in place of the chipset watchdog alerts after an hour",
        "interval": "1m",
        "input_series": [
            {"series": f'up{{{NODE},vm="proxmox"}}', "values": "1x90"},
            {
                "series": 'node_watchdog_info{vm="proxmox",identity="Software Watchdog",state="active"}',
                "values": "1x90",
            },
            {
                "series": 'node_watchdog_info{vm="proxmox",identity="SP5100 TCO timer",state="inactive"}',
                "values": "1x90",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "50m", "alertname": "host_watchdog_unarmed", "exp_alerts": []},
            {
                "eval_time": "70m",
                "alertname": "host_watchdog_unarmed",
                "exp_alerts": [
                    expect("host_watchdog_unarmed", vm="proxmox", identity="SP5100 TCO timer", state="active")
                ],
            },
        ],
    },
    {
        "name": "host: an armed chipset watchdog stays quiet",
        "interval": "1m",
        "input_series": [
            {"series": f'up{{{NODE},vm="proxmox"}}', "values": "1x90"},
            {"series": 'node_watchdog_info{vm="proxmox",identity="SP5100 TCO timer",state="active"}', "values": "1x90"},
        ],
        "alert_rule_test": [{"eval_time": "70m", "alertname": "host_watchdog_unarmed", "exp_alerts": []}],
    },
    {
        "name": "host: security upgrades pending for a week alert, other upgrades never do",
        # within the 5 minute lookback, so the week holds without a gap
        "interval": "4m",
        "input_series": [
            {
                "series": 'apt_upgrades_pending{vm="proxmox",arch="amd64",origin="Debian:trixie-security/stable-security"}',
                "values": "3x2600",
            },
            {
                "series": 'apt_upgrades_pending{vm="proxmox",arch="amd64",origin="Proxmox:trixie/pve-no-subscription"}',
                "values": "40x2600",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "160h", "alertname": "host_security_upgrades", "exp_alerts": []},
            {
                "eval_time": "170h",
                "alertname": "host_security_upgrades",
                "exp_alerts": [expect("host_security_upgrades")],
            },
        ],
    },
    {
        "name": "deploys: a builder without a full pass for two hours pages",
        "interval": "1m",
        "input_series": [
            {"series": f'homelab_app_builder_last_run_timestamp_seconds{{vm="{BUILDER}"}}', "values": "0x200"},
        ],
        "alert_rule_test": [
            {"eval_time": "60m", "alertname": "app_builder_stalled", "exp_alerts": []},
            {"eval_time": "130m", "alertname": "app_builder_stalled", "exp_alerts": [expect("app_builder_stalled")]},
        ],
    },
    {
        "name": "a second failed Minecraft start in an hour alerts, one does not",
        "interval": "5m",
        "input_series": [
            # cobblemon fails once and then a second time; atm10 fails once and comes up
            {"series": 'homelab_mc_start_failures_total{server="cobblemon"}', "values": "0 0 1 1 1 1 2 2 2 2 2 2"},
            {"series": 'homelab_mc_start_failures_total{server="atm10"}', "values": "0 0 1 1 1 1 1 1 1 1 1 1"},
        ],
        "alert_rule_test": [
            {"eval_time": "25m", "alertname": "minecraft_start_failed", "exp_alerts": []},
            {
                "eval_time": "55m",
                "alertname": "minecraft_start_failed",
                "exp_alerts": [expect("minecraft_start_failed", server="cobblemon")],
            },
        ],
    },
    {
        "name": "attack: a ban wave on one ingress pages, the other's scanner trickle stays quiet",
        "interval": "1m",
        "input_series": [
            {"series": 'homelab_gate_bans_total{vm="traefik-external"}', "values": "0+3x90"},
            {"series": 'homelab_gate_bans_total{vm="traefik-internal"}', "values": "0+1x90"},
        ],
        "alert_rule_test": [
            {"eval_time": "20m", "alertname": "ingress_ban_surge", "exp_alerts": []},
            {
                "eval_time": "80m",
                "alertname": "ingress_ban_surge",
                "exp_alerts": [expect("ingress_ban_surge", vm="traefik-external")],
            },
        ],
    },
]


def loki_line_matches(expr, line):
    """Whether a log line passes every line filter (|= substring, |~ regex) of a LogQL query."""
    filters = re.findall(r'\|([=~]) "((?:[^"\\]|\\.)*)"', expr)
    assert filters, f"no line filter in {expr}"
    return all(text in line if op == "=" else re.search(text, line) for op, text in filters)


# the kernel's refusal (modules/network.nix) counts; grafana's own log of the rule's query, which quotes it, does not
GUARD_EXPR = next(d for d in rule_by_uid["guard_refused"]["data"] if d["refId"] == "A")["model"]["expr"]
assert loki_line_matches(GUARD_EXPR, "guard-refused: IN=ens18 OUT= SRC=10.100.0.113 DST=10.100.0.103 PROTO=TCP DPT=22")
assert not loki_line_matches(
    GUARD_EXPR,
    f'logger=tsdb.loki endpoint=queryData query="{GUARD_EXPR}" rule_uid=guard_refused',
), "guard_refused counts grafana's own query log"


def ip_in(address, network):
    return ipaddress.ip_address(address) in ipaddress.ip_network(network, strict=False)


def loki_ssh_login_counts(expr, user, source, method="publickey"):
    """Whether sshd's accept line passes the rule's line filters, regexp stage and label filter."""
    line = f"Accepted {method} for {user} from {source} port 50022 ssh2"
    pattern, label_filter = re.search(r'\| regexp "((?:[^"\\]|\\.)*)" \| (.*) \[\w+\]\)\)$', expr).groups()
    fields = re.search(pattern, line)
    if not loki_line_matches(expr, line) or not fields:
        return False
    python = re.sub(r'(\w+) != ip\("([^"]+)"\)', r'not ip_in(\1, "\2")', label_filter)
    python = re.sub(r'(\w+) = "', r'\1 == "', python)
    return eval(python, {"ip_in": ip_in}, fields.groupdict())


# the lab's forced-command logins stay quiet only as the pair their key allows: a user from its one guest
SSH_LOGIN_EXPR = next(d for d in rule_by_uid["ssh_login_unexpected"]["data"] if d["refId"] == "A")["model"]["expr"]
assert not loki_ssh_login_counts(SSH_LOGIN_EXPR, "archrepo", ARCHBUILD_IP), "the archbuild push alerts"
assert not loki_ssh_login_counts(SSH_LOGIN_EXPR, "root", BUILDER_IP), "the deploy controller's stacks alert"
assert loki_ssh_login_counts(SSH_LOGIN_EXPR, "archrepo", BUILDER_IP), "archrepo from another guest is quiet"
assert loki_ssh_login_counts(SSH_LOGIN_EXPR, "root", ARCHBUILD_IP), "root from the archbuild guest is quiet"
assert loki_ssh_login_counts(SSH_LOGIN_EXPR, "archrepo", ARCHBUILD_IP, method="password"), "a password login is quiet"

# the oracle's own premises: the rules it tests exist, and their paging is what the policy says
for uid, page in (
    ("instance_down", CRITICAL_PAGE),
    ("service_down", CRITICAL_PAGE),
    ("backup_stale", CRITICAL_PAGE),
    ("app_5xx", WARNING_PAGE),
    ("monitoring_unit_down", CRITICAL_PAGE),
):
    assert {k: rule_labels[uid].get(k) for k in page} == page, (uid, rule_labels[uid])
assert "notify" not in rule_labels["watchdog"] and rule_labels["watchdog"]["category"] == "heartbeat"
assert "notify" not in rule_labels["disk_fill_predicted"], "a forecast never pages"

with open(os.path.join(OUT, "tests.json"), "w") as handle:
    json.dump({"rule_files": ["rules.json"], "evaluation_interval": "1m", "tests": tests}, handle, indent=2)
print(f"{len(translated)} of {len(rules)} rules translated, {len(tests)} cases")
