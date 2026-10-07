"""Grafana dashboard of one service, a nixos guest's or a swarm app's: health, resources, routes, logs, traces,
profiles, scrapes.

Usage: service.py <config.json> <out.json>   (run by nix at build time, one board per service, 105-internal-grafana)

Every service with its dashboard on gets this board, whatever it exports. A section appears when its data exists:
routes bring the ingress's requests, refusals and access log and the prober's checks, tcp and udp routes the
router's forwarded connections, a swarm app its deploys and
its containers (cadvisor), a guest its vm (node exporter), logs their loki stream, traces and profiles the service's
own tempo and pyroscope tenant, exporters their scrapes, and the webapp-template's server metrics the template's
own sections. Each section draws the service's budget beside what it uses, so a throttled, dropped or
refused signal reads as the service meeting its own bound.

Config keys:
    name                      the service; board uid service-<name>
    routes                    [{ name; host; ingress; instance; }]: route name, public name, the ingress's promtail
                              `host`, the `instance` of its traefik metrics
    forwards                  { host; loki; routes = [{ name; protocol; port; }]; } the router's journal host, the uid
                              of the loki holding it, the tcp and udp routes it forwards (public port); or null
    deploys                   true for a swarm app: the builder's and the manager's gauges, by `app`
    idle                      true when it stops without traffic: its asleep state
    containers                cadvisor selector of the app's tasks (swarm_stack="<app>"), or null
    vm                        node-exporter `vm` label of a guest, or null
    reservation               { memoryMiB; cpus; } of a swarm app, or null
    logs, loki                LogQL label matchers of the service's lines (swarm_stack="<app>", host="vm-134") and the
                              uid of the loki datasource holding them, or null
    metricsJobs               the service's own scrape jobs
    tenant                    its telemetry tenant
    tempo, pyroscope          the uids of its tenant's datasources, null where the signal is off
    frontend                  true when its browsers send telemetry through the intake: web vitals, errors, traces
    template                  true: add the webapp-template's sections
    budget                    the lab's per-service budget (modules/limits `tenant`)
    routeLimit                { average; burst; amount; } every route admits from all clients together, or null
    cadvisorJob, shipperJob, nodeJob, rateWindow   scrape job names, rate window over the 1m traefik scrape
"""
import json
import sys

import grafana
from grafana import (LOKI, PROMETHEUS, REF_IDS, dashboard, dashboard_write, flamegraph, gauge, geomap, logs, loki, panel,
                     pyroscope, section, series, service_map, stat, state_timeline, target, tempo, traces)

# ---- constants ----------------------------------------------------------------------------------

# cadvisor and the exporters are scraped every 15s; grafana widens this to four scrape intervals and the step
RATE = "$__rate_interval"
LATENCY_QUANTILES = [0.99, 0.95, 0.90, 0.5]
MIB = 1024 * 1024
# a share of a limit or reservation: orange leaves room for a deploy's second task, red does not
USAGE_STEPS = [(None, "green"), (70, "orange"), (90, "red")]
OK_TEXTS = {"0": "failed", "1": "ok"}
OK_STEPS = [(None, "red"), (1, "green")]
# answered by the ingress itself, before the service: waf, crowdsec ban or blocked path, body limit, rate limits
INGRESS_REFUSALS = "403|413|429"
TRACES_SHOWN = 20
SLOW_TRACE = "1s"
ERROR_LINES = "(?i)(error|panic|fatal|exception)"
# cpu time, what the pprof agents (the template's rust server among them) push
PROFILE_TYPE = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
# a task newer than this counts as started
STARTED_WINDOW_S = 300
# traefik names a route's service and router after the route, in the file provider
TRAEFIK_PROVIDER = "@file"
ROUTER_SUFFIX = "-tls"
# the builder's (instances/140-internal-swarm/lib/app-builder.nix) and the manager's (modules/swarm) gauges
DEPLOY_OK = "homelab_swarm_deploy_ok"
DEPLOY_AT = "homelab_swarm_deploy_timestamp_seconds"
BUILD_OK = "homelab_app_deploy_ok"
BUILD_FAILURES = "homelab_app_deploy_failures"
BUILD_LATENCY = "homelab_app_deploy_latency_seconds"
BUILD_IMAGES = "homelab_app_images"
# what the documented browser snippet records (README, frontend telemetry): web vitals as one histogram by name
WEB_VITALS = "browser_web_vital_milliseconds_bucket"
WEB_VITAL_LABEL = "web_vital_name"
# browser log records the sdk marks as errors (loki keeps severity_text as structured metadata)
BROWSER_ERRORS = "(?i)error|fatal"
WEB_VITAL_QUANTILE = 0.75
# promtail's limit stage counts its drops per value of its by_label_name (modules/app-telemetry.nix)
LOG_DROPS = "logentry_dropped_lines_by_label_total"
# tempo and pyroscope count per tenant what they receive and refuse
TRACE_BYTES = "tempo_distributor_bytes_received_total"
TRACE_DISCARDS = "tempo_discarded_spans_total"
PROFILE_BYTES = "pyroscope_distributor_received_decompressed_bytes_sum"
PROFILE_DISCARDS = "pyroscope_discarded_bytes_total"
# the template's filter for "real users": crawlers, uptime probes and wordpress scanners out.
# case-insensitive: Googlebot and bingbot spell it differently
BOT_AGENTS = "(?i).*(bot|crawler).*"
PROBE_AGENT = "worldping-api"
SCANNER_PATHS = "/+wp-.*|.*wordfence.*"
IGNORED_PATHS = ["/robots.txt", "/xmlrpc.php"]
# carried over from the template's filter: its operator's own networks
EXCLUDED_CLIENTS = r"2001:4ca0:108:42:.*|91\.134\.156\..*|37\.59\.149\..*"
TOP_USERS = 5
TOP_AGENTS = 10
TOP_EVENTS = 10


# ---- selectors ----------------------------------------------------------------------------------

def traefik_selector(routes, label, suffix):
    """Exactly these routes' traefik series per ingress: a prefix pattern would match another service <name>-x."""
    by_instance = {}
    for r in routes:
        by_instance.setdefault(r["instance"], []).append(r["name"] + suffix + TRAEFIK_PROVIDER)
    return [f'instance="{instance}", {label}=~"{"|".join(sorted(names))}"' for instance, names in sorted(by_instance.items())]


def sum_over(selectors, expr_of):
    """One expression over every ingress the routes use: their series summed."""
    return " + ".join(f"({expr_of(s)})" for s in selectors) if len(selectors) > 1 else expr_of(selectors[0])


def usage_gauge(title, expr, description):
    return gauge(title, [target(expr, instant=True)], "percent", 0, 100, USAGE_STEPS, decimals=0,
                 description=description)


# ---- sections -----------------------------------------------------------------------------------

def forwards_of(c):
    return c["forwards"]["routes"] if c["forwards"] is not None else []


def health(c):
    app = f'app="{c["name"]}"'
    items = []
    if c["deploys"]:
        mappings = [{"type": "value", "options": {v: {"text": t} for v, t in OK_TEXTS.items()}}]
        items += [
            (stat("Deployed", [target(f"min({DEPLOY_OK}{{{app}}})", instant=True)], "none", steps=OK_STEPS,
                  mappings=mappings, description="The manager's last deploy: render, policy, rollout, no rollback."), 6, 4),
            (stat("Built", [target(f"min({BUILD_OK}{{{app}}})", instant=True)], "none", steps=OK_STEPS,
                  mappings=mappings, description="The builder's newest commit: built, pushed, handed over."), 6, 4),
            (stat("Last deploy", [target(f"max({DEPLOY_AT}{{{app}}}) * 1000", instant=True)], "dateTimeFromNow"), 6, 4),
            (stat("Build failures in a row", [target(f"max({BUILD_FAILURES}{{{app}}}) or vector(0)", instant=True)],
                  "short", steps=[(None, "green"), (1, "red")]), 6, 4),
            (stat("Commit to live", [target(f"max({BUILD_LATENCY}{{{app}}})", instant=True)], "s",
                  description="From the deployed commit's date to its deploy."), 12, 4),
            (stat("Images of the last deploy", [target(f"sum by (how) ({BUILD_IMAGES}{{{app}}})", "{{how}}", instant=True)],
                  "short", description="Built, or reused from the registry because their content did not change."),
             12, 4),
            (state_timeline("Deploys", [target(f"min({DEPLOY_OK}{{{app}}})", "deployed"),
                                        target(f"min({BUILD_OK}{{{app}}})", "built")], OK_TEXTS, OK_STEPS), 24, 4),
        ]
    if c["idle"]:
        items.append((state_timeline("Asleep", [target(f"max(homelab_app_idle_stopped{{{app}}})", "asleep")],
                                     {"0": "awake", "1": "asleep"}, [(None, "green"), (1, "blue")],
                                     description="Stopped after its idle window; the next request wakes it."), 24, 3))
    # udp has no generic probe: a udp route shows its connections only
    probed_names = [r["name"] for r in c["routes"]] + [r["name"] for r in forwards_of(c) if r["protocol"] == "tcp"]
    if probed_names:
        probed = "|".join(sorted(probed_names))
        items.append((state_timeline("Probes", [target(f'probe_success{{service=~"{probed}"}}', "{{service}}")],
                                     {"0": "down", "1": "up"}, OK_STEPS), 24, 4))
    return section("Health", *items) if items else None


def containers(c):
    stack = c["containers"]
    service = stack + ', swarm_service=~"$service"'
    nodes = f'job="{c["cadvisorJob"]}"'

    def by_service(expr):
        return f"sum by (swarm_service) ({expr})"

    items = [
        (usage_gauge("Memory of the workers",
                     f"100 * sum(container_memory_working_set_bytes{{{stack}}}) / sum(machine_memory_bytes{{{nodes}}})",
                     "The stack's memory as a share of the apps nodes' memory."), 6, 6),
        (usage_gauge("CPU of the workers",
                     f"100 * sum(rate(container_cpu_usage_seconds_total{{{stack}}}[{RATE}]))"
                     f" / sum(machine_cpu_cores{{{nodes}}})", "The stack's cpu time as a share of the apps nodes' cores."),
         6, 6),
        (stat("Tasks", [target(f"count(count by (name) (container_start_time_seconds{{{stack}}}))", instant=True)],
              "short", description="Running task containers on every worker."), 6, 6),
        (stat("Network IO",
              [target(f"sum(rate(container_network_receive_bytes_total{{{stack}}}[{RATE}]))", "Input", instant=True),
               target(f"sum(rate(container_network_transmit_bytes_total{{{stack}}}[{RATE}]))", "Output", instant=True)],
              "binBps"), 6, 6),
        (series("CPU Usage by Service",
                [target(by_service(f"rate(container_cpu_usage_seconds_total{{{service}}}[{RATE}])"), "{{swarm_service}}")],
                "percentunit", description="1 is one core; a task cannot exceed its `cpus`."), 12, 10),
        (series("CPU Throttled by Service",
                [target(f"{by_service(f'rate(container_cpu_cfs_throttled_periods_total{{{service}}}[{RATE}])')}"
                        f" / {by_service(f'rate(container_cpu_cfs_periods_total{{{service}}}[{RATE}])')}",
                        "{{swarm_service}}")], "percentunit", maximum=1,
                description="Share of periods the tasks hit their cpu limit: the app at its own bound."), 12, 10),
        (series("Memory Usage by Task", [target(f"container_memory_working_set_bytes{{{service}}}", "{{name}}")],
                "bytes"), 12, 10),
        (series("Memory of the Limit by Task",
                [target(f"container_memory_working_set_bytes{{{service}}}"
                        f" / (container_spec_memory_limit_bytes{{{service}}} > 0)", "{{name}}")], "percentunit",
                maximum=1, description="At 1 the task's own cgroup reclaims, then kills inside the task, nowhere else."),
         12, 10),
        (series("Out of Memory Kills",
                [target(by_service(f"increase(container_oom_events_total{{{service}}}[{RATE}])"), "{{swarm_service}}")],
                "short", bars=True), 8, 8),
        (series("Tasks Started",
                [target(f"count by (swarm_service) (container_start_time_seconds{{{service}}} > time() - "
                        f"{STARTED_WINDOW_S})", "{{swarm_service}}")], "short", bars=True,
                description=f"Tasks younger than {STARTED_WINDOW_S}s: deploys, restarts, replacements."), 8, 8),
        (series("Threads of the Limit by Task",
                [target(f"container_threads{{{service}}} / (container_threads_max{{{service}}} > 0)", "{{name}}")],
                "percentunit", maximum=1, description="Processes and threads against the task's `pids`."), 8, 8),
        (series("Network IO by Service",
                [target(by_service(f"rate(container_network_receive_bytes_total{{{service}}}[{RATE}])"),
                        "{{swarm_service}} - Receive"),
                 target(by_service(f"rate(container_network_transmit_bytes_total{{{service}}}[{RATE}])"),
                        "{{swarm_service}} - Transmit")], "binBps"), 12, 10),
        (series("Disk IO by Service",
                [target(by_service(f"rate(container_fs_reads_bytes_total{{{service}}}[{RATE}])"), "{{swarm_service}} - Read"),
                 target(by_service(f"rate(container_fs_writes_bytes_total{{{service}}}[{RATE}])"),
                        "{{swarm_service}} - Write")], "binBps"), 12, 10),
    ]
    if c["reservation"] is not None:
        memory = c["reservation"]["memoryMiB"]
        items.insert(0, (usage_gauge("Memory of the Reservation",
                                     f"100 * sum(container_memory_working_set_bytes{{{stack}}}) / {memory * MIB}",
                                     f"The stack's memory against its reservation of {memory} MiB."), 24, 5))
    return section("Resources", *items)


def guest(c):
    vm = f'job="{c["nodeJob"]}", vm="{c["vm"]}"'
    return section(
        "Resources",
        (series("CPU", [target(f'1 - avg(rate(node_cpu_seconds_total{{{vm}, mode="idle"}}[{RATE}]))', "busy")],
                "percentunit", maximum=1), 8, 8),
        (series("Memory", [target(f"1 - node_memory_MemAvailable_bytes{{{vm}}} / node_memory_MemTotal_bytes{{{vm}}}",
                                  "used")], "percentunit", maximum=1), 8, 8),
        (series("Network IO",
                [target(f'sum(rate(node_network_receive_bytes_total{{{vm}, device!="lo"}}[{RATE}]))', "Receive"),
                 target(f'sum(rate(node_network_transmit_bytes_total{{{vm}, device!="lo"}}[{RATE}]))', "Transmit")],
                "binBps"), 8, 8),
    )


def ingress(c):
    window = c["rateWindow"]
    services = traefik_selector(c["routes"], "service", "")
    routers = traefik_selector(c["routes"], "router", ROUTER_SUFFIX)
    hosts = "|".join(sorted({r["host"].replace(".", "\\\\.") for r in c["routes"]}))
    access_of = {r["ingress"] for r in c["routes"]}
    access = f'{{job="traefik-access", host=~"{"|".join(sorted(access_of))}"}} | json | RequestHost=~`{hosts}`'

    def requests(span, codes=""):
        code = f', code=~"{codes}"' if codes else ""
        return sum_over(services, lambda s: f"sum(increase(traefik_service_requests_total{{{s}{code}}}[{span}]))")

    rate = [target(sum_over(services, lambda s: f"sum by (code) (rate(traefik_service_requests_total{{{s}}}[{window}]))"),
                   "HTTP {{code}}")]
    if c["routeLimit"] is not None:
        rate.append(target(f"vector({c['routeLimit']['average']})", "limit per route"))
    return section(
        "Routes",
        (stat("Requests per Status Code",
              [target(sum_over(services, lambda s: f"sum by (code) (increase(traefik_service_requests_total{{{s}}}[$__range]))"),
                      "HTTP {{code}}", instant=True)], "short", decimals=0), 12, 5),
        (stat("Total Requests", [target(requests("$__range"), instant=True)], "short", decimals=0), 4, 5),
        (stat("% of 4xx Requests", [target(f'100 * ({requests("$__range", "4..")}) / ({requests("$__range")})',
                                           instant=True)], "percent", decimals=1, color="orange"), 4, 5),
        (stat("% of 5xx Requests", [target(f'100 * ({requests("$__range", "5..")}) / ({requests("$__range")})',
                                           instant=True)], "percent", decimals=1, color="red"), 4, 5),
        (series("HTTP Requests", rate, "reqps"), 12, 10),
        (series("Request Time Percentiles",
                [target(f"histogram_quantile({q}, sum by (le) ("
                        + sum_over(services, lambda s: f"rate(traefik_service_request_duration_seconds_bucket{{{s}}}[{window}])")
                        + "))", f"{round(q * 100)}th percentile") for q in LATENCY_QUANTILES], "s"), 12, 10),
        (series("Refused at the Ingress",
                [target(sum_over(routers, lambda s: f'sum by (code) (rate(traefik_router_requests_total{{{s}, '
                                                    f'code=~"{INGRESS_REFUSALS}"}}[{window}]))'), "HTTP {{code}}")],
                "reqps", stack=True, description="429 a rate limit, 403 the waf, a crowdsec ban or a blocked path, "
                                                 "413 the body limit: answered before the service."), 12, 10),
        (logs("Access Log", access), 12, 10),
    )


def forwards_section(c):
    """New connections the router forwards to the service's tcp and udp routes, from the log it keeps of them."""
    f = c["forwards"]
    source = loki(f["loki"])
    lines = {r["name"]: f'{{host="{f["host"]}"}} |= "forward {r["port"]}: "' for r in f["routes"]}
    pattern = "|".join(str(r["port"]) for r in f["routes"])
    return section(
        "Forwards",
        (series("New Connections", [target(f"sum(count_over_time({expr} [$__interval]))", name, datasource=source)
                                    for name, expr in sorted(lines.items())], "short", bars=True, datasource=source,
                description="As the router logs them: rate-capped, so a flood shows as the cap."), 12, 8),
        (logs("Forwarded Clients", f'{{host="{f["host"]}"}} |~ "forward ({pattern}): "', datasource=source), 12, 8),
    )


def logs_section(c):
    budget, source = c["budget"], loki(c["loki"])
    selector = "{" + c["logs"] + (', swarm_service=~"$service"' if c["containers"] is not None else "") + "}"
    items = [
        (series("Log Lines", [target(f"sum(count_over_time({selector} [$__interval]))", "lines", datasource=source)],
                "short", bars=True, datasource=source), 12, 8),
        (series("Error Lines", [target(f"sum(count_over_time({selector} |~ `{ERROR_LINES}` [$__interval]))", "errors",
                                       datasource=source)], "short", bars=True, datasource=source), 12, 8),
    ]
    if c["containers"] is not None:
        items.append((series("Dropped at the Shipper",
                             [target(f'sum(rate({LOG_DROPS}{{job="{c["shipperJob"]}", label_name="swarm_stack", '
                                     f'label_value="{c["name"]}"}}[{RATE}]))', "dropped lines/s"),
                              target(f"vector({budget['logLinesPerSecond']})", "budget lines/s")], "short",
                             description=f"Lines above {budget['logLinesPerSecond']}/s (burst {budget['logBurstLines']})"
                                         " never leave the worker; other apps' lines do not wait on them."), 24, 8))
    items.append((logs("Logs", selector, datasource=source), 24, 14))
    return section("Logs", *items)


def traces_section(c):
    tenant, window = f'tenant="{c["tenant"]}"', c["rateWindow"]
    source = tempo(c["tempo"])
    return section(
        "Traces",
        (series("Spans per Second by Service",
                [target(f"sum by (service) (rate(traces_spanmetrics_calls_total{{{tenant}}}[{window}]))", "{{service}}")],
                "ops"), 12, 9),
        (series("Span Latency p95 by Service",
                [target(f"histogram_quantile(0.95, sum by (service, le) (rate(traces_spanmetrics_latency_bucket"
                        f"{{{tenant}}}[{window}])))", "{{service}}")], "s"), 12, 9),
        (series("Ingested and Refused",
                [target(f"sum(rate({TRACE_BYTES}{{{tenant}}}[{window}]))", "received bytes/s"),
                 target(f"sum by (reason) (rate({TRACE_DISCARDS}{{{tenant}}}[{window}]))", "discarded spans/s ({{reason}})"),
                 target(f"vector({c['budget']['traceBytesPerSecond']})", "budget bytes/s")], "short",
                description="Spans above the tenant's budget are refused at tempo; other tenants are untouched."), 12, 9),
        (service_map("Service Graph", source, f"{{{tenant}}}"), 12, 9),
        (traces("Recent Traces", source, "{}", TRACES_SHOWN), 12, 10),
        (traces(f"Traces over {SLOW_TRACE}", source, f"{{ duration > {SLOW_TRACE} }}", TRACES_SHOWN), 12, 10),
    )


def frontend_section(c):
    tenant, window = f'tenant="{c["tenant"]}"', c["rateWindow"]
    source = loki(c["loki"])
    return section(
        "Frontend",
        (series(f"Web Vitals p{round(WEB_VITAL_QUANTILE * 100)}",
                [target(f"histogram_quantile({WEB_VITAL_QUANTILE}, sum by (le, {WEB_VITAL_LABEL}) (rate({WEB_VITALS}"
                        f"{{{tenant}}}[{window}])))", f"{{{{{WEB_VITAL_LABEL}}}}}")], "ms",
                description="Largest contentful paint, interaction to next paint, layout shift and friends, as the "
                            "browsers measured them."), 12, 9),
        (series("Browser Errors",
                [target(f"sum(count_over_time({{service_name=~\".+\"}} | severity_text=~`{BROWSER_ERRORS}` [$__interval]))",
                        "errors", datasource=source)], "short", bars=True, datasource=source), 12, 9),
        (traces("Browser Traces", tempo(c["tempo"]), '{ kind = client }', TRACES_SHOWN,
                description="A browser span carries traceparent to the backend: one trace spans both."), 24, 10),
    )


def profiles_section(c):
    tenant, window = f'tenant="{c["tenant"]}"', c["rateWindow"]
    return section(
        "Profiles",
        (series("Ingested and Refused",
                [target(f"sum(rate({PROFILE_BYTES}{{{tenant}}}[{window}]))", "received bytes/s"),
                 target(f"sum by (reason) (rate({PROFILE_DISCARDS}{{{tenant}}}[{window}]))", "discarded bytes/s ({{reason}})"),
                 target(f"vector({c['budget']['profileBytesPerSecond']})", "budget bytes/s")], "binBps",
                description="Profiles above the tenant's budget are refused at pyroscope."), 24, 7),
        (flamegraph("CPU", pyroscope(c["pyroscope"]), PROFILE_TYPE), 24, 16),
    )


def scrapes(c):
    jobs, samples = "|".join(c["metricsJobs"]), c["budget"]["scrapeSamples"]
    return section(
        "Scrapes",
        (state_timeline("Exporters Up", [target(f'up{{job=~"{jobs}"}}', "{{job}}")], {"0": "down", "1": "up"},
                        OK_STEPS), 12, 6),
        (series("Samples per Scrape", [target(f'scrape_samples_scraped{{job=~"{jobs}"}}', "{{job}}"),
                                       target(f"vector({samples})", "limit")], "short",
                description=f"A scrape above {samples} samples fails whole: this exporter's series stop, no other's."),
         12, 6),
    )


# ---- the webapp-template's sections ------------------------------------------------------------
#
# A port of the template's services/monitoring/grafana/provisioning/dashboards/metrics.json for the apps exporting
# its server metrics. Its nginx access log is the edge's here (visitors, agents, countries), its minio panels show
# garage (the data volume's disk in place of the bucket size, which garage does not export), and its HTTP and System
# rows are the Routes and Resources sections above. Template bugs fixed on the way: Open Sessions counted a metric
# that does not exist (pg_stat_activity_count is the exporter's), Total API Requests counted samples instead of
# requests, the totals showed the last interval instead of the range, the 4xx/5xx shares divided by 100, the mean
# response time summed ratios, and CPU Usage Total showed cores on a percent axis.


def template_stat(title, targets, unit, datasource=PROMETHEUS, decimals=0, color="blue", **kw):
    """The template's stat: counts read 0, not "-", while nothing happened."""
    return grafana.stat(title, targets, unit, decimals=decimals, color=color, no_value="0", datasource=datasource,
                        text_mode="auto", **kw)


def template_table(title, expr, label, label_title, value_title, datasource):
    return grafana.table(title, target(expr, instant=True, datasource=datasource), label, label_title, value_title,
                         datasource=datasource)


def users(app, request_host, edge_host):
    prom_app = f'app="{app}"'
    # line filter first: json-parsing every other host's lines would dominate the query
    access = (f'{{job="traefik-access", host="{edge_host}"}} |= `{request_host}`'
              ' | json ClientHost, RequestHost, RequestPath, request_User_Agent="[\\"request_User-Agent\\"]"'
              f' | __error__="" | RequestHost=`{request_host}`')
    humans = (access
              + f" | request_User_Agent !~ `{BOT_AGENTS}` | request_User_Agent != `{PROBE_AGENT}`"
              + f" | ClientHost !~ `{EXCLUDED_CLIENTS}` | RequestPath !~ `{SCANNER_PATHS}`"
              + "".join(f" | RequestPath != `{p}`" for p in IGNORED_PATHS))

    def visitors(window):
        return f"count(sum by (ClientHost) (count_over_time({humans} [{window}])))"

    def endpoint_total(endpoint):
        return (f'sum(increase(axum_http_requests_total{{{prom_app}, endpoint="{endpoint}", status="200"}}[$__range]))'
                " or vector(0)")

    return section(
        "User Metrics",
        *[(template_stat(f"Unique User Visits ({span})", [target(visitors("$__range"), instant=True, datasource=LOKI)], "short",
                         datasource=LOKI, color="purple", time_from=span,
                         description="Distinct client IPs on the edge, crawlers, probes and scanners left out."), 8, 4)
          for span in ("1h", "24h", "7d")],
        (template_stat("Open Sessions", [target(f'sum(pg_stat_activity_count{{{prom_app}, state="active"}}) or vector(0)',
                                                instant=True)], "short", description="Active postgres connections."), 8, 4),
        (template_stat("Logins", [target(endpoint_total("/api/auth/login"), instant=True)], "short", color="green"), 8, 4),
        (template_stat("Registrations", [target(endpoint_total("/api/auth/register"), instant=True)], "short", color="green"),
         8, 4),
        (geomap("User Locations", target(f"sum by (country) (count_over_time({humans} [$__range]))", instant=True,
                                         datasource=LOKI), "Visitors"), 24, 15),
        (series("Unique User Visits (rolling 24h)", [target(visitors("1d"), "visitors", datasource=LOKI)], "short",
                datasource=LOKI, time_from="7d", interval="1h"), 12, 8),
        (series("Unique User Visits (per day)", [target(visitors("$__interval"), "visitors", datasource=LOKI)],
                "short", datasource=LOKI, time_from="30d", interval="1d"), 12, 8),
        (template_table("Top Users", f"topk({TOP_USERS}, sum by (ClientHost) (count_over_time({humans} [$__range])))",
                        "ClientHost", "Client IP", "Requests", LOKI), 12, 10),
        (template_table("Top User Agents",
                        f"topk({TOP_AGENTS}, sum by (request_User_Agent) (count_over_time({humans} [$__range])))",
                        "request_User_Agent", "User agent", "Requests", LOKI), 12, 10),
    )


def api(app):
    api_selector = f'app="{app}", endpoint=~"/api/.*"'

    def api_rate(statuses):
        return target(f'sum by (method, status, endpoint) (rate(axum_http_requests_total{{{api_selector}, '
                      f'status=~"{statuses}"}}[{RATE}]))', "{{method}} {{status}} {{endpoint}}")

    return section(
        "API Metrics",
        (template_stat("Total API Requests",
                       [target(f"sum(increase(axum_http_requests_total{{{api_selector}}}[$__range]))", instant=True)], "short"),
         6, 5),
        (series("API Requests per Second",
                [target(f"sum by (endpoint) (rate(axum_http_requests_total{{{api_selector}}}[{RATE}]))",
                        "{{endpoint}}")], "reqps"), 18, 11),
        (series("Average API Response Time",
                [target(f"sum by (endpoint) (rate(axum_http_requests_duration_seconds_sum{{{api_selector}}}[{RATE}]))"
                        f" / sum by (endpoint) (rate(axum_http_requests_duration_seconds_count{{{api_selector}}}"
                        f"[{RATE}]))", "{{endpoint}}")], "s"), 24, 11),
        (series("200 API Requests per Second", [api_rate("2..")], "reqps"), 8, 11),
        (series("400 API Requests per Second", [api_rate("4..")], "reqps"), 8, 11),
        (series("500 API Requests per Second", [api_rate("5..")], "reqps"), 8, 11),
    )


def stores(app):
    prom_app = f'app="{app}"'
    return section(
        "Database Metrics",
        (series("Postgres Transactions",
                [target(f"sum by (datname) (rate(pg_stat_database_xact_commit{{{prom_app}}}[{RATE}]))",
                        "Commits - {{datname}}"),
                 target(f"sum by (datname) (rate(pg_stat_database_xact_rollback{{{prom_app}}}[{RATE}]))",
                        "Rollbacks - {{datname}}")], "ops"), 12, 11),
        (series("Postgres Size", [target(f"pg_database_size_bytes{{{prom_app}}}", "{{datname}}")], "bytes"), 12, 11),
        (series("Redis Activity",
                [target(f"rate(redis_commands_processed_total{{{prom_app}}}[{RATE}])", "Commands/sec")], "ops"),
         12, 11),
        (series("Redis Size (in Memory)", [target(f"redis_memory_used_bytes{{{prom_app}}}", "Used")], "bytes"), 12, 11),
        (series("Garage Activity",
                [target(f"sum by (api_endpoint) (rate(api_s3_request_counter{{{prom_app}}}[{RATE}]))",
                        "{{api_endpoint}}")], "reqps"), 12, 11),
        (series("Garage Size",
                [target(f'garage_local_disk_total{{{prom_app}, volume="data"}}'
                        f' - garage_local_disk_avail{{{prom_app}, volume="data"}}', "Used"),
                 target(f'garage_local_disk_total{{{prom_app}, volume="data"}}', "Total")], "bytes",
                description="Disk use of garage's data volume; garage exports no bucket sizes."), 12, 11),
        (series("PostgreSQL Errors",
                [target(f"sum by (datname) (rate(pg_stat_database_xact_rollback{{{prom_app}}}[{RATE}]))",
                        "Rollbacks - {{datname}}"),
                 target(f"sum by (datname) (rate(pg_stat_database_conflicts{{{prom_app}}}[{RATE}]))",
                        "Conflicts - {{datname}}")], "ops"), 8, 11),
        (series("Redis Errors",
                [target(f"rate(redis_rejected_connections_total{{{prom_app}}}[{RATE}])", "Rejected Connections"),
                 target(f"rate(redis_keyspace_misses_total{{{prom_app}}}[{RATE}])", "Keyspace Misses"),
                 target(f"rate(redis_evicted_keys_total{{{prom_app}}}[{RATE}])", "Evicted Keys")], "ops"), 8, 11),
        (series("Garage Errors",
                [target(f"sum by (api_endpoint, status_code) (rate(api_s3_error_counter{{{prom_app}}}[{RATE}]))",
                        "{{api_endpoint}} {{status_code}}")], "ops"), 8, 11),
    )


def client(app):
    prom_app = f'app="{app}"'
    return section(
        "Client Analytics",
        (series("Client Events per Second",
                [target(f"sum by (event) (rate(client_event_total{{{prom_app}}}[{RATE}]))", "{{event}}")], "ops"),
         24, 11),
        (template_stat("Total Client Events",
                       [target(f"sum(increase(client_event_total{{{prom_app}}}[$__range])) or vector(0)", instant=True)],
                       "short"), 6, 5),
        (template_table("Top Client Events",
                        f"topk({TOP_EVENTS}, sum by (event) (increase(client_event_total{{{prom_app}}}[$__range])))",
                        "event", "Event", "Count", PROMETHEUS), 18, 5),
    )


def board_of(c):
    sections = [health(c)]
    if c["containers"] is not None:
        sections.append(containers(c))
    if c["vm"] is not None:
        sections.append(guest(c))
    if c["routes"]:
        sections.append(ingress(c))
    if forwards_of(c):
        sections.append(forwards_section(c))
    if c["logs"] is not None:
        sections.append(logs_section(c))
    if c["tempo"] is not None:
        sections.append(traces_section(c))
    if c["pyroscope"] is not None:
        sections.append(profiles_section(c))
    if c["frontend"] and c["tempo"] is not None:
        sections.append(frontend_section(c))
    if c["metricsJobs"]:
        sections.append(scrapes(c))
    if c["template"]:
        host = c["routes"][0]
        app = c["name"]
        sections += [users(app, host["host"], host["ingress"]), api(app), stores(app), client(app)]
    variables = []
    if c["containers"] is not None:
        variables.append({"name": "service", "label": "Service", "type": "query", "datasource": PROMETHEUS,
                          "query": {"query": f"label_values(container_start_time_seconds{{{c['containers']}}}, swarm_service)",
                                    "refId": "A"}, "refresh": 2, "includeAll": True, "multi": True,
                          "current": {"text": "All", "value": "$__all"}})
    # one scrape interval; faster only redraws the same samples
    return dashboard(c["name"], f"service-{c['name']}", [s for s in sections if s is not None], time_from="now-1h",
                     refresh="15s", tags=("service", c["name"]), variables=variables)


# ---- the overview: every service in one table, each row linking to its board ---------------------

def overview_of(configs):
    """One row per service: its health, traffic, resources and telemetry volume, a click away from its board."""
    window = configs[0]["rateWindow"] if configs else "5m"

    def requests(c, codes=""):
        code = f', code=~"{codes}"' if codes else ""
        return sum_over(traefik_selector(c["routes"], "service", ""),
                        lambda s: f"sum(rate(traefik_service_requests_total{{{s}{code}}}[{window}]))")

    def latency(c):
        buckets = sum_over(traefik_selector(c["routes"], "service", ""),
                           lambda s: f"sum by (le) (rate(traefik_service_request_duration_seconds_bucket{{{s}}}[{window}]))")
        return f"histogram_quantile(0.95, {buckets})"

    def memory(c):
        if c["containers"] is not None:
            return f'sum(container_memory_working_set_bytes{{{c["containers"]}}})'
        vm = f'job="{c["nodeJob"]}", vm="{c["vm"]}"'
        return f"node_memory_MemTotal_bytes{{{vm}}} - node_memory_MemAvailable_bytes{{{vm}}}"

    def tenant(metric):
        return lambda c: f'sum(rate({metric}{{tenant="{c["tenant"]}"}}[{window}]))' if c["deploys"] else None

    # title, unit, the service's expression or None
    columns = [
        ("Deployed", "none", lambda c: f'min(homelab_swarm_deploy_ok{{app="{c["name"]}"}})' if c["deploys"] else None),
        ("Asleep", "none", lambda c: f'max(homelab_app_idle_stopped{{app="{c["name"]}"}})' if c["deploys"] else None),
        ("Requests/s", "reqps", lambda c: requests(c) if c["routes"] else None),
        ("5xx %", "percent", lambda c: f"100 * ({requests(c, '5..')}) / ({requests(c)})" if c["routes"] else None),
        ("p95", "s", lambda c: latency(c) if c["routes"] else None),
        ("Memory", "bytes", memory),
        ("Log lines/s", "short", tenant("loki_distributor_lines_received_total")),
        ("Trace bytes/s", "binBps", tenant(TRACE_BYTES)),
        ("Profile bytes/s", "binBps", tenant(PROFILE_BYTES)),
    ]
    targets, renames, units = [], {}, {}
    for title, unit, expr_of in columns:
        parts = [f'label_replace({expr_of(c)}, "service", "{c["name"]}", "", "")' for c in configs if expr_of(c) is not None]
        if parts:
            renames[f"Value #{REF_IDS[len(targets)]}"] = title
            units[title] = unit
            targets.append(target(" or ".join(parts), instant=True))
    link = {"title": "Open the service's board", "url": "/d/service-${__value.raw}"}
    overrides = [{"matcher": {"id": "byName", "options": "service"}, "properties": [{"id": "links", "value": [link]}]}]
    overrides += [{"matcher": {"id": "byName", "options": t}, "properties": [{"id": "unit", "value": u}]}
                  for t, u in units.items()]
    services = panel("table", "Services", targets,
                     transformations=[{"id": "merge", "options": {}},
                                      {"id": "organize", "options": {"excludeByName": {"Time": True},
                                                                     "renameByName": renames}}],
                     fieldConfig={"defaults": {"custom": {"align": "auto"}}, "overrides": overrides},
                     options={"showHeader": True, "cellHeight": "sm"})
    return dashboard("Services", "services", [section("Every service", (services, 24, 20))], time_from="now-1h",
                     refresh="30s", tags=("service",))


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        config = json.load(f)
    dashboard_write(overview_of(config["services"]) if "services" in config else board_of(config), sys.argv[2])
