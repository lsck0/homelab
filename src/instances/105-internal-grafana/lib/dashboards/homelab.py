"""Grafana dashboard "Homelab": guests, traffic, access, system and logs on one board.

Usage: homelab.py <config.json> <out.json>   (run by nix at build time, see 105-internal-grafana.nix)

Config keys: uid (the board's, modules/telemetry.nix homelabDashboardUid), nodeJob (the node-exporter scrape job),
guestsExpectedUp (the `up` series of every guest meant to run, the same expression as the instance_down alert),
edgeHost and ssoHost (promtail `host` of the public ingress and of authelia), nasVm and hostVm (`vm` label of the
nas guest and the proxmox host).
"""
import json
import sys
from functools import partial

from grafana import (LOKI, PROMETHEUS, bar_gauge, dashboard, dashboard_write, geomap, logs, section, series, stat,
                     table, target)

# ---- constants ----------------------------------------------------------------------------------

with open(sys.argv[1]) as f:
    config = json.load(f)

NODE = f'job="{config["nodeJob"]}"'
EDGE_ACCESS = f'{{job="traefik-access", host="{config["edgeHost"]}"}}'
ACCESS = '{job="traefik-access"}'
SSO = f'{{host="{config["ssoHost"]}", unit="authelia-main.service"}}'
NAS_ROOT = f'vm="{config["nasVm"]}",mountpoint="/"'
HOST_ROOT = f'vm="{config["hostVm"]}",mountpoint="/"'
# the traefik and node jobs scrape every 1m: four samples
RATE_WINDOW = "5m"
TOP_ROWS = 15
TOP_SIGN_IN_ROWS = 10
BACKUP_LATE_S = 26 * 3600
BACKUP_MISSING_S = 50 * 3600
HOST_ROOT_LOW_BYTES = 5e9
HOST_ROOT_OK_BYTES = 20e9
# the proxmox host's collectors (prometheus-node-exporter-collectors); visible when absent, not "fine"
NO_COLLECTOR = "no collector"
JOURNAL = '{job="systemd-journal", level=~"error|crit|alert|emerg"}'
JOURNAL_WARNINGS = '{job="systemd-journal", level=~"error|warning|crit|alert|emerg"}'

# the board's line style: smooth, filled, legend table beside the graph
line = partial(series, smooth=True, line_width=2, fill=12, legend_right=True, minimum=0)
loki_table = partial(table, datasource=LOKI)


def loki_top(expr, label, rows=TOP_ROWS):
    return target(f"topk({rows}, sum by ({label}) (count_over_time({expr} [$__range])))", instant=True,
                  datasource=LOKI)


def per_vm(expr):
    return target(f"sort_desc({expr})", "{{vm}}", instant=True)


cpu_busy = f'100 - (avg by (vm) (rate(node_cpu_seconds_total{{mode="idle",vm=~"$vm"}}[{RATE_WINDOW}])) * 100)'
memory_used = ('100 * (1 - (sum by (vm) (node_memory_MemAvailable_bytes{vm=~"$vm"})'
               ' / sum by (vm) (node_memory_MemTotal_bytes{vm=~"$vm"})))')
root_used = ('100 * (1 - (max by (vm) (node_filesystem_avail_bytes{mountpoint="/",vm=~"$vm"})'
             ' / max by (vm) (node_filesystem_size_bytes{mountpoint="/",vm=~"$vm"})))')
traffic = (f'sum by (vm) (rate(node_network_receive_bytes_total{{device!="lo",vm=~"$vm"}}[{RATE_WINDOW}])'
           f' + rate(node_network_transmit_bytes_total{{device!="lo",vm=~"$vm"}}[{RATE_WINDOW}]))')
service_requests = 'traefik_service_requests_total{service=~"$service"}'
latency_bucket = f'rate(traefik_service_request_duration_seconds_bucket{{service=~"$service"}}[{RATE_WINDOW}])'

# ---- sections -----------------------------------------------------------------------------------

overview = section(
    "Overview",
    (stat("VMs up", [target(f"count({config['guestsExpectedUp']} == 1)", instant=True)], "short"), 4, 4),
    (stat("VMs down", [target(f"count({config['guestsExpectedUp']} == 0) or vector(0)", instant=True)], "short",
          steps=[(None, "green"), (1, "red")],
          description="Guests meant to run (inventory enabled) that do not answer; the Guest offline alert's set."), 4, 4),
    (stat("Alerts firing", [target("count(homelab_alert_firing) or vector(0)", instant=True)], "short",
          steps=[(None, "green"), (1, "red")]), 4, 4),
    (stat("Last backup", [target("time() - max(homelab_backup_last_success_timestamp_seconds)", instant=True)], "s",
          0, steps=[(None, "green"), (BACKUP_LATE_S, "yellow"), (BACKUP_MISSING_S, "red")]), 4, 4),
    (stat("Host root free", [target(f"node_filesystem_avail_bytes{{{HOST_ROOT}}}", instant=True)], "bytes", 1,
          steps=[(None, "red"), (HOST_ROOT_LOW_BYTES, "yellow"), (HOST_ROOT_OK_BYTES, "green")]), 4, 4),
    (stat("Disks", [target("min(smartmon_device_smart_healthy)", instant=True)], "short",
          steps=[(None, "red"), (1, "green")], no_value=NO_COLLECTOR,
          mappings=[{"type": "value", "options": {"1": {"text": "Healthy"}, "0": {"text": "FAILING"}}}],
          description="SMART health of the proxmox host's disks (smartmon collector)."), 4, 4),
    (stat("Requests", [target("sum(increase(traefik_service_requests_total[$__range]))", instant=True)], "short", 0,
          "purple"), 4, 4),
    (stat("Public requests", [target(f"sum(count_over_time({EDGE_ACCESS}[$__range]))", instant=True,
                                     datasource=LOKI)], "short", 0, "purple", datasource=LOKI), 4, 4),
    (stat("Unique public visitors",
          [target(f'count(sum by (ClientHost) (count_over_time({EDGE_ACCESS} | json ClientHost | __error__="" '
                  f'[$__range])))', instant=True, datasource=LOKI)], "short", 0, "purple", datasource=LOKI), 4, 4),
    (stat("5xx", [target('100 * sum(increase(traefik_service_requests_total{code=~"5.."}[$__range]))'
                         ' / clamp_min(sum(increase(traefik_service_requests_total[$__range])), 1)', instant=True)],
          "percent", 2, steps=[(None, "green"), (1, "yellow"), (5, "red")]), 4, 4),
    (stat("NAS free", [target(f"100 * node_filesystem_avail_bytes{{{NAS_ROOT}}} / node_filesystem_size_bytes{{{NAS_ROOT}}}",
                              instant=True)], "percent", 0, steps=[(None, "red"), (10, "yellow"), (25, "green")]), 4, 4),
    (stat("NVMe wear", [target("max(nvme_percentage_used_ratio)", instant=True)], "percentunit", 0,
          steps=[(None, "green"), (0.5, "yellow"), (0.8, "red")], no_value=NO_COLLECTOR,
          description="Rated write endurance used by the proxmox host's nvme (nvme collector)."), 4, 4),
)

traffic_section = section(
    "Traffic",
    (geomap("Request origins", target('sum by (country) (count_over_time({job="traefik-access", country=~".+"} [$__range]))',
                                      instant=True, datasource=LOKI), "Requests"), 16, 14),
    (loki_table("Top countries", loki_top('{job="traefik-access", country=~".+"}', "country"), "country",
                "Country", "Requests"), 8, 14),
    (line("Requests/sec by status", [target(f"sum by (code) (rate({service_requests}[{RATE_WINDOW}]))", "{{code}}")],
          "reqps", stack=True, legend_calcs=["mean", "max", "lastNotNull"], legend_sort="Mean"), 12, 9),
    (line("Latency", [target(f"histogram_quantile({q}, sum by (le) ({latency_bucket}))", f"p{round(q * 100)}")
                      for q in (0.50, 0.90, 0.99)],
          "s", legend_calcs=["mean", "max", "lastNotNull"], legend_sort="Max"), 12, 9),
    (bar_gauge("Requests by service",
               [target(f'sort_desc(label_replace(sum by (service) (increase({service_requests}[$__range])),'
                       f' "service", "$1", "service", "([^@]+)@.*"))', "{{service}}", instant=True)],
               "short", [(None, "green")], color_mode="continuous-BlYlRd"), 8, 12),
    (loki_table("Top hosts", loki_top(f'{ACCESS} | json RequestHost | __error__=""', "RequestHost"),
                "RequestHost", "Host", "Requests"), 8, 12),
    (loki_table("Rejected public paths (4xx/5xx)",
                loki_top(f'{EDGE_ACCESS} | json DownstreamStatus, RequestPath | __error__="" | DownstreamStatus >= 400',
                         "RequestPath"), "RequestPath", "Path", "Requests"), 8, 12),
)

access = section(
    "Access (who is calling)",
    (loki_table("Top client IPs", loki_top(f'{ACCESS} | json ClientHost | __error__=""', "ClientHost"),
                "ClientHost", "Client IP", "Requests"), 8, 11),
    (loki_table("Top user agents",
                loki_top(f'{ACCESS} | json request_User_Agent="[\\"request_User-Agent\\"]" | __error__=""',
                         "request_User_Agent"), "request_User_Agent", "User agent", "Requests"), 8, 11),
    (loki_table("Top requested paths", loki_top(f'{ACCESS} | json RequestPath | __error__=""', "RequestPath"),
                "RequestPath", "Path", "Requests"), 8, 11),
    (loki_table("Top IPs getting 4xx/5xx",
                loki_top(f'{ACCESS} | json ClientHost, DownstreamStatus | __error__="" | DownstreamStatus >= 400',
                         "ClientHost"), "ClientHost", "Client IP", "Requests"), 8, 11),
    (loki_table("Failed sign-ins by user (Authelia)",
                loki_top(SSO + ' |= "Unsuccessful 1FA" | regexp "by user \'(?P<user>[^\']+)\'"', "user",
                         TOP_SIGN_IN_ROWS), "user", "User", "Attempts"), 8, 11),
    (loki_table("Rejected sign-ins by IP (Authelia)",
                loki_top(f'{SSO} |~ "Unsuccessful|failed|denied" | logfmt', "remote_ip",
                         TOP_SIGN_IN_ROWS), "remote_ip", "Client IP", "Attempts"), 8, 11),
)

system = section(
    "System (by VM)",
    (bar_gauge("CPU now", [per_vm(cpu_busy)], "percent", [(None, "green"), (60, "yellow"), (85, "red")], maximum=100),
     8, 12),
    (line("CPU busy", [target(cpu_busy, "{{vm}}")], "percent", maximum=100,
          legend_calcs=["mean", "max", "lastNotNull"], legend_sort="Mean"), 16, 12),
    (bar_gauge("Memory now", [per_vm(memory_used)], "percent", [(None, "green"), (75, "yellow"), (90, "red")],
               maximum=100), 8, 12),
    (line("Memory used", [target(memory_used, "{{vm}}")], "percent", maximum=100,
          legend_calcs=["mean", "max", "lastNotNull"], legend_sort="Last *"), 16, 12),
    (bar_gauge("Disk used (root)", [per_vm(root_used)], "percent", [(None, "green"), (75, "yellow"), (90, "red")],
               maximum=100), 8, 12),
    (line("Network throughput (rx + tx)", [target(traffic, "{{vm}}")], "Bps", legend_calcs=["mean", "max"],
          legend_sort="Mean"), 16, 12),
)

log_section = section(
    "Logs",
    (line("Errors and warnings by host",
          [target(f"sum by (host) (count_over_time({JOURNAL_WARNINGS} [$__interval]))", "{{host}}", datasource=LOKI)],
          "short", bars=True, stack=True, legend_calcs=["sum"], legend_sort="Total", datasource=LOKI), 24, 9),
    (logs("Recent errors", JOURNAL), 24, 12),
)

variables = [
    {"name": "vm", "label": "VM", "type": "query", "datasource": PROMETHEUS,
     "query": {"query": f"label_values(up{{{NODE}}}, vm)", "refId": "A"}, "refresh": 2, "includeAll": True,
     "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
    {"name": "service", "label": "Service", "type": "query", "datasource": PROMETHEUS,
     "query": {"query": "label_values(traefik_service_requests_total, service)", "refId": "A"}, "refresh": 2,
     "includeAll": True, "multi": True, "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "sort": 1},
]

board = dashboard("Homelab", config["uid"], [overview, traffic_section, access, system, log_section], tags=("homelab",),
                  variables=variables)

if __name__ == "__main__":
    dashboard_write(board, sys.argv[2])
