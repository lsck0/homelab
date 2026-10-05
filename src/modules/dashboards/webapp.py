"""Grafana dashboard for one webapp-template stack: users, http, api, stores, containers, client events.

Usage: webapp.py <config.json> <out.json>   (run by nix at build time, see 105-internal-grafana.nix)

A port of the template's services/monitoring/grafana/provisioning/dashboards/metrics.json, one panel
for each of its panels, rewritten for the homelab:

- Its nginx access log is the edge traefik's here (vm-200 promtail, job traefik-access): visitors,
  agents and countries come from that log, request counts, status shares and latencies from the
  traefik_service_* metrics of the app's routes.
- Its minio panels show garage, the template's actual store: s3 requests and errors per endpoint,
  and the data volume's disk use in place of the bucket size, which garage does not export.
- Its cadvisor filter on compose names matches the swarm task names <app>_<service>.<slot>.<id>,
  and the per-container panels group by the swarm_service label the scrape derives from them.

Template bugs fixed on the way: Open Sessions counted series of a metric that does not exist
(pg_stat_activity_count is the exporter's), Total API Requests counted samples (count_over_time)
instead of requests, Logins, Registrations and the totals showed the last interval instead of the
range, the 4xx/5xx shares divided by 100 instead of multiplying, the mean response time summed
ratios, and CPU Usage Total showed cores on a percent axis.

Config keys: app (stack and `app` scrape label), requestHost (public name), edgeHost (promtail
`host` of the edge), edgeTraefikTarget (its metrics `instance`), traefikServices (regex over traefik
service names), traefikRateWindow.
"""
import json
import sys

# ---- constants -----------------------------------------------------------------------------

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}

GRID_COLUMNS = 24
# the app scrapes every 15s (105-internal-grafana.nix appScrapeInterval); grafana widens this to
# four scrape intervals and to the step, so a rate never sees fewer than four samples
RATE = "$__rate_interval"
LATENCY_QUANTILES = [0.99, 0.95, 0.90, 0.75, 0.5]
TOP_USERS = 5
TOP_AGENTS = 10
TOP_EVENTS = 10
# the stack's share of the apps nodes: orange leaves room for a deploy's second task, red does not
USAGE_WARN_PERCENT = 70
USAGE_CRITICAL_PERCENT = 90

# the template's filter for "real users": crawlers, uptime probes and wordpress scanners out.
# case-insensitive: Googlebot and bingbot spell it differently
BOT_AGENTS = "(?i).*(bot|crawler).*"
PROBE_AGENT = "worldping-api"
SCANNER_PATHS = "/+wp-.*|.*wordfence.*"
IGNORED_PATHS = ["/robots.txt", "/xmlrpc.php"]
# carried over from the template's filter: its operator's own networks
EXCLUDED_CLIENTS = r"2001:4ca0:108:42:.*|91\.134\.156\..*|37\.59\.149\..*"

with open(sys.argv[1]) as f:
    config = json.load(f)

APP = config["app"]
REQUEST_HOST = config["requestHost"]
TRAEFIK_WINDOW = config["traefikRateWindow"]

PROM_APP = f'app="{APP}"'
CONTAINERS = f'name=~"{APP}_.*"'
CADVISOR_NODES = 'job="app-cadvisor"'
SERVICE = f'instance="{config["edgeTraefikTarget"]}", service=~"{config["traefikServices"]}"'
API = f'{PROM_APP}, endpoint=~"/api/.*"'

# line filter first: json-parsing every other host's lines would dominate the query
ACCESS = (f'{{job="traefik-access", host="{config["edgeHost"]}"}} |= `{REQUEST_HOST}`'
          ' | json ClientHost, RequestHost, RequestPath, request_User_Agent="[\\"request_User-Agent\\"]"'
          f' | __error__="" | RequestHost=`{REQUEST_HOST}`')
HUMANS = (ACCESS
          + f" | request_User_Agent !~ `{BOT_AGENTS}` | request_User_Agent != `{PROBE_AGENT}`"
          + f" | ClientHost !~ `{EXCLUDED_CLIENTS}` | RequestPath !~ `{SCANNER_PATHS}`"
          + "".join(f" | RequestPath != `{p}`" for p in IGNORED_PATHS))

# ---- layout --------------------------------------------------------------------------------

panels = []
y, x_cursor, row_h = 0, 0, 0


def place(panel, w, h):
    """Left to right, wrapping at the grid width."""
    global y, x_cursor, row_h
    if x_cursor + w > GRID_COLUMNS:
        y += row_h
        x_cursor, row_h = 0, 0
    panel["gridPos"] = {"x": x_cursor, "y": y, "w": w, "h": h}
    x_cursor += w
    row_h = max(row_h, h)
    panels.append(panel)


def row(title):
    global y, x_cursor, row_h
    y += row_h
    x_cursor, row_h = 0, 0
    panels.append({"type": "row", "title": title, "collapsed": False, "panels": [],
                   "gridPos": {"x": 0, "y": y, "w": GRID_COLUMNS, "h": 1}})
    y += 1


# ---- panels --------------------------------------------------------------------------------

def target(expr, legend="", ref="A", instant=False, ds=PROMETHEUS, interval=None):
    t = {"refId": ref, "datasource": ds, "expr": expr, "legendFormat": legend or "__auto",
         "instant": instant, "range": not instant}
    if ds is LOKI:
        t["queryType"] = "instant" if instant else "range"
    if interval:
        t["interval"] = interval
    return t


def refs(targets):
    for i, t in enumerate(targets):
        t["refId"] = chr(ord("A") + i)
    return targets


def stat(title, targets, unit, ds=PROMETHEUS, decimals=0, color="blue", time_from=None, description=None):
    p = {"type": "stat", "title": title, "datasource": ds,
         "fieldConfig": {"defaults": {"unit": unit, "decimals": decimals, "color": {"mode": "thresholds"},
                                      "noValue": "0",
                                      "thresholds": {"mode": "absolute", "steps": [{"color": color, "value": None}]}},
                         "overrides": []},
         "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "textMode": "auto",
                     "wideLayout": True,
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
         "targets": refs(targets)}
    if time_from:
        p["timeFrom"] = time_from
    if description:
        p["description"] = description
    return p


def gauge(title, expr, description=None):
    p = {"type": "gauge", "title": title, "datasource": PROMETHEUS,
         "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 0,
                                      "color": {"mode": "thresholds"},
                                      "thresholds": {"mode": "absolute", "steps": [
                                          {"color": "green", "value": None},
                                          {"color": "orange", "value": USAGE_WARN_PERCENT},
                                          {"color": "red", "value": USAGE_CRITICAL_PERCENT}]}},
                         "overrides": []},
         "options": {"showThresholdLabels": False, "showThresholdMarkers": True,
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
         "targets": [target(expr, instant=True)]}
    if description:
        p["description"] = description
    return p


def series(title, targets, unit, ds=PROMETHEUS, time_from=None, interval=None, description=None, stack=False):
    p = {"type": "timeseries", "title": title, "datasource": ds,
         "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "palette-classic"},
                                      "custom": {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10,
                                                 "showPoints": "never", "spanNulls": False,
                                                 "stacking": {"mode": "normal" if stack else "none", "group": "A"}}},
                         "overrides": []},
         "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                     "tooltip": {"mode": "multi", "sort": "desc"}},
         "targets": refs(targets)}
    if time_from:
        p["timeFrom"] = time_from
    if interval:
        p["interval"] = interval
    if description:
        p["description"] = description
    return p


def table(title, expr, label, label_title, value_title, ds):
    return {"type": "table", "title": title, "datasource": ds,
            "targets": [target(expr, instant=True, ds=ds)],
            "transformations": [
                {"id": "labelsToFields", "options": {"mode": "columns"}},
                {"id": "merge", "options": {}},
                {"id": "organize", "options": {"excludeByName": {"Time": True},
                                               "renameByName": {label: label_title, "Value": value_title},
                                               "indexByName": {label: 0, "Value": 1}}},
                {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": value_title, "desc": True}]}}],
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"align": "auto", "cellOptions": {"type": "auto"}}},
                            "overrides": [{"matcher": {"id": "byName", "options": value_title},
                                           "properties": [{"id": "custom.cellOptions",
                                                           "value": {"type": "gauge", "mode": "gradient"}},
                                                          {"id": "custom.width", "value": 140}]}]},
            "options": {"showHeader": True, "cellHeight": "sm",
                        "footer": {"show": False, "reducer": ["sum"], "countRows": False, "fields": ""}}}


def geomap(title, expr):
    """Markers per country, the same layer as the Homelab board's request origins."""
    return {"type": "geomap", "title": title, "datasource": LOKI,
            "targets": [target(expr, instant=True, ds=LOKI)],
            "transformations": [{"id": "labelsToFields", "options": {"mode": "columns"}},
                                {"id": "merge", "options": {}}],
            "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
                                         "thresholds": {"mode": "absolute", "steps": [
                                             {"color": "green", "value": None}]}},
                            "overrides": []},
            "options": {"view": {"allLayers": True, "id": "zero", "lat": 0, "lon": 0, "zoom": 1},
                        "basemap": {"type": "carto", "name": "Basemap", "config": {"theme": "dark", "showLabels": False}},
                        "controls": {"mouseWheelZoom": True, "showZoom": True, "showAttribution": True},
                        "tooltip": {"mode": "details"},
                        "layers": [{"type": "markers", "name": "Visitors", "tooltip": True,
                                    "location": {"mode": "lookup", "lookup": "country",
                                                 "gazetteer": "public/gazetteer/countries.json"},
                                    "config": {"showLegend": True, "style": {
                                        "size": {"field": "Value", "fixed": 5, "min": 2, "max": 15},
                                        "color": {"field": "Value"}, "opacity": 0.4,
                                        "symbol": {"fixed": "img/icons/marker/circle.svg", "mode": "fixed"},
                                        "text": {"field": "country", "mode": "field"}}}}]}}


# ---- queries -------------------------------------------------------------------------------

def visitors(window):
    return f"count(sum by (ClientHost) (count_over_time({HUMANS} [{window}])))"


def requests(window, codes=None):
    code = f', code=~"{codes}"' if codes else ""
    return f"sum(increase(traefik_service_requests_total{{{SERVICE}{code}}}[{window}]))"


def api_rate(statuses):
    return target(f'sum by (method, status, endpoint) (rate(axum_http_requests_total{{{API}, status=~"{statuses}"}}[{RATE}]))',
                  "{{method}} {{status}} {{endpoint}}")


def endpoint_total(endpoint):
    return (f'sum(increase(axum_http_requests_total{{{PROM_APP}, endpoint="{endpoint}", status="200"}}[$__range]))'
            " or vector(0)")


def by_service(expr):
    return f"sum by (swarm_service) ({expr})"


# ---- user metrics --------------------------------------------------------------------------

row("User Metrics")
for span, label in [("1h", "1h"), ("24h", "24h"), ("7d", "7d")]:
    place(stat(f"Unique User Visits ({label})", [target(visitors("$__range"), instant=True, ds=LOKI)], "short",
               ds=LOKI, color="purple", time_from=span,
               description="Distinct client IPs on the edge, crawlers, probes and scanners left out."), 8, 4)
place(stat("Open Sessions", [target(f'sum(pg_stat_activity_count{{{PROM_APP}, state="active"}}) or vector(0)',
                                    instant=True)], "short",
           description="Active postgres connections."), 8, 4)
place(stat("Logins", [target(endpoint_total("/api/auth/login"), instant=True)], "short", color="green"), 8, 4)
place(stat("Registrations", [target(endpoint_total("/api/auth/register"), instant=True)], "short", color="green"), 8, 4)
place(geomap("User Locations", f"sum by (country) (count_over_time({HUMANS} [$__range]))"), 24, 15)
place(series("Unique User Visits (rolling 24h)", [target(visitors("1d"), "visitors", ds=LOKI)], "short", ds=LOKI,
             time_from="7d", interval="1h"), 12, 8)
place(series("Unique User Visits (per day)", [target(visitors("$__interval"), "visitors", ds=LOKI)], "short",
             ds=LOKI, time_from="30d", interval="1d"), 12, 8)
place(table("Top Users", f"topk({TOP_USERS}, sum by (ClientHost) (count_over_time({HUMANS} [$__range])))",
            "ClientHost", "Client IP", "Requests", LOKI), 12, 10)
place(table("Top User Agents",
            f"topk({TOP_AGENTS}, sum by (request_User_Agent) (count_over_time({HUMANS} [$__range])))",
            "request_User_Agent", "User agent", "Requests", LOKI), 12, 10)

# ---- http metrics: the edge's view of every route of the app -------------------------------

row("HTTP Metrics")
place(stat("Requests per Status Code",
           [target(f"sum by (code) (increase(traefik_service_requests_total{{{SERVICE}}}[$__range]))",
                   "HTTP {{code}}", instant=True)], "short"), 12, 9)
place(stat("Total Requests", [target(requests("$__range"), instant=True)], "short"), 6, 5)
place(stat("Total API Requests",
           [target(f"sum(increase(axum_http_requests_total{{{API}}}[$__range]))", instant=True)], "short"), 6, 5)
place(stat("% of 4xx Requests", [target(f'100 * {requests("$__range", "4..")} / {requests("$__range")}',
                                        instant=True)], "percent", decimals=1, color="orange"), 6, 4)
place(stat("% of 5xx Requests", [target(f'100 * {requests("$__range", "5..")} / {requests("$__range")}',
                                        instant=True)], "percent", decimals=1, color="red"), 6, 4)
place(series("HTTP Requests",
             [target(f"sum by (code) (rate(traefik_service_requests_total{{{SERVICE}}}[{TRAEFIK_WINDOW}]))",
                     "HTTP {{code}}")], "reqps", stack=True), 12, 11)
place(series("Request Time Percentiles",
             [target(f"histogram_quantile({q}, sum by (le) (rate(traefik_service_request_duration_seconds_bucket"
                     f"{{{SERVICE}}}[{TRAEFIK_WINDOW}])))", f"{round(q * 100)}th percentile")
              for q in LATENCY_QUANTILES], "s"), 12, 11)

# ---- api metrics: the server's own counters ------------------------------------------------

row("API Metrics")
place(series("API Requests per Second",
             [target(f"sum by (endpoint) (rate(axum_http_requests_total{{{API}}}[{RATE}]))", "{{endpoint}}")],
             "reqps"), 12, 11)
place(series("Average API Response Time",
             [target(f"sum by (endpoint) (rate(axum_http_requests_duration_seconds_sum{{{API}}}[{RATE}]))"
                     f" / sum by (endpoint) (rate(axum_http_requests_duration_seconds_count{{{API}}}[{RATE}]))",
                     "{{endpoint}}")], "s"), 12, 11)
place(series("200 API Requests per Second", [api_rate("2..")], "reqps"), 8, 11)
place(series("400 API Requests per Second", [api_rate("4..")], "reqps"), 8, 11)
place(series("500 API Requests per Second", [api_rate("5..")], "reqps"), 8, 11)

# ---- stores --------------------------------------------------------------------------------

row("Database Metrics")
place(series("Postgres Transactions",
             [target(f"sum by (datname) (rate(pg_stat_database_xact_commit{{{PROM_APP}}}[{RATE}]))", "Commits - {{datname}}"),
              target(f"sum by (datname) (rate(pg_stat_database_xact_rollback{{{PROM_APP}}}[{RATE}]))",
                     "Rollbacks - {{datname}}")], "ops"), 12, 11)
place(series("Postgres Size", [target(f"pg_database_size_bytes{{{PROM_APP}}}", "{{datname}}")], "bytes"), 12, 11)
place(series("Redis Activity",
             [target(f"rate(redis_commands_processed_total{{{PROM_APP}}}[{RATE}])", "Commands/sec")], "ops"), 12, 11)
place(series("Redis Size (in Memory)", [target(f"redis_memory_used_bytes{{{PROM_APP}}}", "Used")], "bytes"), 12, 11)
place(series("Garage Activity",
             [target(f"sum by (api_endpoint) (rate(api_s3_request_counter{{{PROM_APP}}}[{RATE}]))", "{{api_endpoint}}")],
             "reqps"), 12, 11)
place(series("Garage Size",
             [target(f'garage_local_disk_total{{{PROM_APP}, volume="data"}} - garage_local_disk_avail{{{PROM_APP}, volume="data"}}',
                     "Used"),
              target(f'garage_local_disk_total{{{PROM_APP}, volume="data"}}', "Total")], "bytes",
             description="Disk use of garage's data volume; garage exports no bucket sizes."), 12, 11)
place(series("PostgreSQL Errors",
             [target(f"sum by (datname) (rate(pg_stat_database_xact_rollback{{{PROM_APP}}}[{RATE}]))",
                     "Rollbacks - {{datname}}"),
              target(f"sum by (datname) (rate(pg_stat_database_conflicts{{{PROM_APP}}}[{RATE}]))",
                     "Conflicts - {{datname}}")], "ops"), 8, 11)
place(series("Redis Errors",
             [target(f"rate(redis_rejected_connections_total{{{PROM_APP}}}[{RATE}])", "Rejected Connections"),
              target(f"rate(redis_keyspace_misses_total{{{PROM_APP}}}[{RATE}])", "Keyspace Misses"),
              target(f"rate(redis_evicted_keys_total{{{PROM_APP}}}[{RATE}])", "Evicted Keys")], "ops"), 8, 11)
place(series("Garage Errors",
             [target(f"sum by (api_endpoint, status_code) (rate(api_s3_error_counter{{{PROM_APP}}}[{RATE}]))",
                     "{{api_endpoint}} {{status_code}}")], "ops"), 8, 11)

# ---- containers ----------------------------------------------------------------------------

row("System Metrics")
place(gauge("Memory Usage Total",
            f"100 * sum(container_memory_working_set_bytes{{{CONTAINERS}}}) / sum(machine_memory_bytes{{{CADVISOR_NODES}}})",
            description="The stack's memory as a share of the apps nodes' memory."), 6, 6)
place(gauge("CPU Usage Total",
            f"100 * sum(rate(container_cpu_usage_seconds_total{{{CONTAINERS}}}[{RATE}]))"
            f" / sum(machine_cpu_cores{{{CADVISOR_NODES}}})",
            description="The stack's cpu time as a share of the apps nodes' cores."), 6, 6)
place(stat("Network IO",
           [target(f"sum(rate(container_network_receive_bytes_total{{{CONTAINERS}}}[{RATE}]))", "Input", instant=True),
            target(f"sum(rate(container_network_transmit_bytes_total{{{CONTAINERS}}}[{RATE}]))", "Output",
                   instant=True)], "binBps", decimals=None), 12, 6)
place(series("Network IO by Container",
             [target(by_service(f"rate(container_network_receive_bytes_total{{{CONTAINERS}}}[{RATE}])"),
                     "{{swarm_service}} - Receive"),
              target(by_service(f"rate(container_network_transmit_bytes_total{{{CONTAINERS}}}[{RATE}])"),
                     "{{swarm_service}} - Transmit")], "binBps"), 24, 11)
place(series("CPU Usage by Container",
             [target(by_service(f"rate(container_cpu_usage_seconds_total{{{CONTAINERS}}}[{RATE}])"),
                     "{{swarm_service}}")], "percentunit",
             description="1 is one core."), 12, 11)
place(series("Memory Usage by Container",
             [target(by_service(f"container_memory_working_set_bytes{{{CONTAINERS}}}"), "{{swarm_service}}")],
             "bytes"), 12, 11)

# ---- client analytics ----------------------------------------------------------------------

row("Client Analytics")
place(series("Client Events per Second",
             [target(f"sum by (event) (rate(client_event_total{{{PROM_APP}}}[{RATE}]))", "{{event}}")], "ops"), 24, 11)
place(stat("Total Client Events",
           [target(f"sum(increase(client_event_total{{{PROM_APP}}}[$__range])) or vector(0)", instant=True)],
           "short"), 6, 5)
place(table("Top Client Events",
            f"topk({TOP_EVENTS}, sum by (event) (increase(client_event_total{{{PROM_APP}}}[$__range])))",
            "event", "Event", "Count", PROMETHEUS), 18, 5)

dashboard = {
    "title": APP,
    "uid": f"app-{APP}",
    "tags": ["app", APP],
    "timezone": "browser",
    "editable": True,
    "graphTooltip": 1,
    "schemaVersion": 41,
    "time": {"from": "now-1h", "to": "now"},
    # one scrape interval; faster only redraws the same samples
    "refresh": "15s",
    "templating": {"list": []},
    "panels": panels,
}

with open(sys.argv[2], "w") as f:
    json.dump(dashboard, f, indent=2, ensure_ascii=False)
