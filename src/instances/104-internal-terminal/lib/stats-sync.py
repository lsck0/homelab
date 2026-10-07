"""Build the TRMNL homelab dashboard payload.

Usage: stats-sync.py <out-dir>
Env:   STATS_PROMETHEUS, STATS_LOKI, STATS_QBITTORRENT (base urls), STATS_INVENTORY (the inventory json with a `vm`
       name per guest, 104-internal-terminal/main.nix), STATS_TOKENS (lab token dir), STATS_CLIENT_INGRESS and
       STATS_EDGE_ADDRESS (promtail `host` and address of the public ingress), STATS_CLIENT_DOMAIN (suffix stripped
       from host names), the layout knobs below

What reaches TRMNL's cloud: guest names, load and state, request counts per route, visitor countries, agents and
host names of the public ingress, disk use, and torrent counts and progress. Torrent names only with
STATS_TORRENT_NAMES=1; without, a row shows the torrent's category.
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import feed_io

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

PROMETHEUS = os.environ.get("STATS_PROMETHEUS", "")
LOKI = os.environ.get("STATS_LOKI", "")
QBITTORRENT = os.environ.get("STATS_QBITTORRENT", "")
INVENTORY = os.environ.get("STATS_INVENTORY", "")
TOKENS = os.environ.get("STATS_TOKENS", "")
# six columns of seven
SERVICE_ROWS = int(os.environ.get("STATS_SERVICE_ROWS", "42"))
TORRENT_ROWS = int(os.environ.get("STATS_TORRENT_ROWS", "4"))
# more rows than fit clips the last one
REQUEST_ROWS = int(os.environ.get("STATS_REQUEST_ROWS", "13"))
REQUEST_WINDOW = os.environ.get("STATS_REQUEST_WINDOW", "3h")
DISK_ROWS = int(os.environ.get("STATS_DISK_ROWS", "4"))
# longest torrent name fitting one line
NAME_CHARS = int(os.environ.get("STATS_NAME_CHARS", "42"))
# the "who is calling" strip
CLIENT_INGRESS = os.environ.get("STATS_CLIENT_INGRESS", "")
# the public ingress's address: its traefik's requests come from the internet
EDGE_ADDRESS = os.environ.get("STATS_EDGE_ADDRESS", "")
CLIENT_WINDOW = os.environ.get("STATS_CLIENT_WINDOW", "24h")
CLIENT_ROWS = int(os.environ.get("STATS_CLIENT_ROWS", "13"))
# shared domain suffix stripped from hostnames
CLIENT_DOMAIN = os.environ.get("STATS_CLIENT_DOMAIN", "")
# names are what a stranger reads off the panel or the cloud; categories say as much on the wall
TORRENT_NAMES = os.environ.get("STATS_TORRENT_NAMES", "0") == "1"
QBITTORRENT_TIMEOUT_S = 8
# qbittorrent's "no estimate": 100 days
ETA_UNKNOWN_S = 8640000
# the proxmox host's `vm` label: the lab's real cpu and memory, summed guests are oversubscribed
HOST_VM = os.environ.get("STATS_HOST_VM", "proxmox")
# rate() window of the load and throughput gauges
RATE_WINDOW = "5m"
NETWORK_TOP_ROWS = 4
PERCENT = 100
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
SECONDS_PER_DAY = 86400
BYTES_PER_KIB = 1024
# a scaled value below this keeps one decimal
DECIMAL_BELOW = 10
RATE_UNITS = ("B", "K", "M", "G")
SIZE_UNITS = ("B", "KB", "MB", "GB", "TB")
# traefik router name suffixes of one route: its tls, relay and block routers
ROUTER_SUFFIXES = ("-tls", "-relay", "-block")

# raw user-agents are too many; bucket into families
AGENT_FAMILY = (
    '{{ if or (contains "bot" .ua) (contains "Bot" .ua) (contains "crawl" .ua)'
    ' (contains "spider" .ua) }}bot'
    '{{ else if contains "Edg/" .ua }}Edge'
    '{{ else if contains "Chrome/" .ua }}Chrome'
    '{{ else if contains "Firefox/" .ua }}Firefox'
    '{{ else if contains "Safari/" .ua }}Safari'
    '{{ else if or (contains "Go-http" .ua) (contains "connect-go" .ua) }}Go'
    '{{ else if or (contains "curl" .ua) (contains "Wget" .ua) }}curl'
    '{{ else }}other{{ end }}'
)

# qbittorrent's many states reduced to three buckets
DOWNLOADING = {"downloading", "metaDL", "stalledDL", "queuedDL", "forcedDL", "checkingDL"}
SEEDING = {"uploading", "stalledUP", "queuedUP", "forcedUP", "checkingUP"}
PAUSED = {"pausedDL", "pausedUP", "stoppedDL", "stoppedUP"}

# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------


def promql(query):
    """One instant query's rows; [] when prometheus failed, which the payload reports as unreachable."""
    return feed_io.prometheus_query(PROMETHEUS, query) or []


def logql(query):
    """One instant Loki query; same contract as promql."""
    return feed_io.loki_query(LOKI, query) or []


def scalar(rows, default=0.0):
    """The first row's value of an instant query, default when there is none."""
    try:
        return float(rows[0]["value"][1])
    except (IndexError, KeyError, TypeError, ValueError):
        return default


def percent_clamp(value):
    """A whole percent for the template's bars."""
    return min(PERCENT, max(0, round(value)))


def by_label(results, label):
    """label value -> float."""
    out = {}
    for r in results:
        key = r["metric"].get(label)
        if not key:
            continue
        try:
            out[key] = float(r["value"][1])
        except (TypeError, ValueError):
            continue
    return out


def human_scaled(value, units):
    """value in the first of units (each BYTES_PER_KIB times the last) that keeps it below BYTES_PER_KIB."""
    v = float(value)
    for unit in units:
        if v < BYTES_PER_KIB or unit == units[-1]:
            break
        v /= BYTES_PER_KIB
    return f"{v:.0f}{unit}" if v >= DECIMAL_BELOW or unit == units[0] else f"{v:.1f}{unit}"


def human_rate(bytes_per_s):
    return human_scaled(bytes_per_s, RATE_UNITS) + "/s"


def human_size(num):
    return human_scaled(num, SIZE_UNITS)


def human_count(n):
    if n < 1000:
        return str(int(n))
    if n < 10000:
        return f"{n / 1000:.1f}k"
    if n < 1000000:
        return f"{n / 1000:.0f}k"
    return f"{n / 1000000:.1f}M"


def bars(pairs, scale=None):
    """(name, count) -> rows with pct of the largest (or scale)."""
    top = scale if scale is not None else max((c for _, c in pairs), default=0)
    return [{
        "name": n,
        "count": human_count(c),
        "pct": round(PERCENT * c / top) if top else 0,
    } for n, c in pairs]


def ranked(results, label, fallback="?"):
    """Loki vector -> the label's values, largest first, with share bars."""
    out = []
    for r in results:
        try:
            out.append((r["metric"].get(label) or fallback, float(r["value"][1])))
        except (KeyError, TypeError, ValueError):
            continue
    out.sort(key=lambda kv: -kv[1])
    return bars(out[:CLIENT_ROWS])


def eta(seconds, pct):
    if pct >= PERCENT:
        return "done"
    if not seconds or seconds >= ETA_UNKNOWN_S:
        return ""
    if seconds < SECONDS_PER_HOUR:
        return f"{seconds // SECONDS_PER_MINUTE}m"
    if seconds < SECONDS_PER_DAY:
        return f"{seconds // SECONDS_PER_HOUR}h"
    return f"{seconds // SECONDS_PER_DAY}d"


# -----------------------------------------------------------------------------
# SECTIONS
# -----------------------------------------------------------------------------


def services():
    """One row per declared VM, down ones included."""
    inv = feed_io.file_json_load(INVENTORY)
    if inv is None:
        feed_io.log(f"no inventory at {INVENTORY}; no guest rows")
        inv = {}

    # by the `vm` label prometheus and the inventory share (modules/telemetry.nix vmName)
    up = by_label(promql('up{job="homelab-node-exporter"}'), "vm")
    cpu = by_label(promql(f'100 - (avg by (vm) (rate(node_cpu_seconds_total{{mode="idle"}}[{RATE_WINDOW}])) * 100)'), "vm")
    mem = by_label(promql('(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'), "vm")

    rows = []
    for vmid, vm in sorted(inv.items(), key=lambda kv: int(kv[0])):
        name = vm["vm"]
        enabled = vm.get("enabled", "true")
        online = up.get(name, 0) >= 1
        rows.append({
            "vmid": vmid,
            "name": name,
            "online": online,
            "disabled": enabled == "false",
            "on_demand": enabled == "onDemand",
            "cpu": round(cpu.get(name, 0.0), 1) if online else 0.0,
            "mem": round(mem.get(name, 0.0), 1) if online else 0.0,
            "cpu_pct": percent_clamp(cpu.get(name, 0.0)) if online else 0,
            "mem_pct": percent_clamp(mem.get(name, 0.0)) if online else 0,
        })

    expected = [r for r in rows if not r["disabled"]]
    # cpu tile's second line names the busiest vm
    busiest = max(expected, key=lambda r: r["cpu_pct"], default=None)
    return rows, {
        "up": sum(1 for r in expected if r["online"]),
        "total": len(expected),
        "down": [r["name"] for r in expected if not r["online"] and not r["on_demand"]],
        "off": len(rows) - len(expected),
        "busiest": {"name": busiest["name"], "cpu_pct": busiest["cpu_pct"]} if busiest else None,
    }


def network():
    """Lab throughput and busiest hosts, virtual devices excluded."""
    real = 'device!~"lo|veth.*|docker.*|podman.*|br-.*|cni.*|tailscale.*|wg.*"'
    rx = promql(f'sum(rate(node_network_receive_bytes_total{{{real}}}[{RATE_WINDOW}]))')
    tx = promql(f'sum(rate(node_network_transmit_bytes_total{{{real}}}[{RATE_WINDOW}]))')
    top = promql(
        f'topk({NETWORK_TOP_ROWS}, sum by (vm) ('
        f'rate(node_network_receive_bytes_total{{{real}}}[{RATE_WINDOW}])'
        f' + rate(node_network_transmit_bytes_total{{{real}}}[{RATE_WINDOW}])))')
    return {
        "rx": human_rate(scalar(rx)),
        "tx": human_rate(scalar(tx)),
        "top": [{
            "vm": r["metric"].get("vm", "?"),
            "rate": human_rate(float(r["value"][1])),
        } for r in top],
    }


def totals():
    """Host cpu and memory; summed guests are oversubscribed."""
    sel = f'{{vm="{HOST_VM}"}}'
    idle = f'{{vm="{HOST_VM}",mode="idle"}}'
    busy = scalar(promql(
        f'100 * (1 - (sum(rate(node_cpu_seconds_total{idle}[{RATE_WINDOW}]))'
        f' / sum(rate(node_cpu_seconds_total{sel}[{RATE_WINDOW}]))))'))
    cores = scalar(promql(f'count(count by (cpu) (node_cpu_seconds_total{sel}))'))
    mem_total = scalar(promql(f'node_memory_MemTotal_bytes{sel}'))
    mem_free = scalar(promql(f'node_memory_MemAvailable_bytes{sel}'))
    used = mem_total - mem_free

    return {
        "cpu_pct": percent_clamp(busy),
        "cores": int(cores),
        "mem_pct": round(used / mem_total * PERCENT) if mem_total else 0,
        "mem_used": human_size(used),
        "mem_total": human_size(mem_total),
    }


def requests():
    """Request counts per route over REQUEST_WINDOW, lan vs internet."""
    rows = promql(f'sum by (router, instance)'
                  f' (increase(traefik_router_requests_total[{REQUEST_WINDOW}]))')
    by_router = {}
    for r in rows:
        name = r["metric"].get("router", "")
        if not name:
            continue
        # "forgejo-tls@file" is the router; the suffixes are Traefik's own
        name = name.split("@")[0]
        for suffix in ROUTER_SUFFIXES:
            if name.endswith(suffix):
                name = name[: -len(suffix)]
        try:
            hits = float(r["value"][1])
        except (TypeError, ValueError):
            continue
        external = r["metric"].get("instance", "").split(":")[0] == EDGE_ADDRESS
        e = by_router.setdefault(name, {"name": name, "int": 0.0, "ext": 0.0})
        e["ext" if external else "int"] += hits

    out = []
    for e in by_router.values():
        total = e["int"] + e["ext"]
        if total < 1:
            continue
        out.append({
            "name": e["name"],
            "rate": total,
            "rpm": human_count(total),
            # origin in one word, not two columns
            "origin": "ext" if e["ext"] > e["int"] else ("int" if e["int"] else "ext"),
            "mixed": e["int"] > 0 and e["ext"] > 0,
        })
    out.sort(key=lambda x: -x["rate"])
    out = out[:REQUEST_ROWS]
    top = out[0]["rate"] if out else 0
    for e in out:
        e["pct"] = round(PERCENT * e.pop("rate") / top) if top else 0
    return out


def clients():
    """Internet visitors over the last day, from the access log."""
    # __error__="" drops non-json access log lines
    sel = f'{{job="traefik-access", host="{CLIENT_INGRESS}"}}'
    w = CLIENT_WINDOW
    k = CLIENT_ROWS

    # no Cf-Ipcountry means it bypassed cloudflare
    countries = ranked(
        logql(f'topk({k}, sum by (country) (count_over_time({sel}[{w}])))'),
        "country", "direct")
    agents = ranked(
        logql(f'topk({k}, sum by (agent) (count_over_time({sel}'
              f' | json ua=`["request_User-Agent"]` | __error__=""'
              f' | label_format agent=`{AGENT_FAMILY}` [{w}])))'),
        "agent", "other")
    hosts = ranked(
        logql(f'topk({k}, sum by (h) (count_over_time({sel}'
              f' | json h="RequestHost" | __error__="" [{w}])))'),
        "h", "direct")
    for h in hosts:
        if h["name"].endswith(CLIENT_DOMAIN):
            h["name"] = h["name"][: -len(CLIENT_DOMAIN)]
        elif h["name"][:1].isdigit():
            # bare ip host header is a scanner
            h["name"] = "by address"

    # how that traffic went
    by_status, exact = {}, {}
    for r in logql(f'sum by (status) (count_over_time({sel}[{w}]))'):
        code = str(r["metric"].get("status") or "")
        try:
            n = float(r["value"][1])
        except (KeyError, TypeError, ValueError):
            continue
        klass = code[:1] + "xx" if code[:1].isdigit() else "?"
        by_status[klass] = by_status.get(klass, 0.0) + n
        exact[code] = exact.get(code, 0.0) + n
    total = sum(by_status.values())

    # ClientHost is real: cloudflare ranges are trusted
    visitors = scalar(logql(
        f'count(count by (ip) (count_over_time({sel} | json ip="ClientHost"'
        f' | __error__="" [{w}])))'))

    # method label is on the stream, so free
    by_method = {}
    for r in logql(f'sum by (method) (count_over_time({sel}[{w}]))'):
        try:
            by_method[r["metric"].get("method") or "?"] = float(r["value"][1])
        except (KeyError, TypeError, ValueError):
            continue

    rows = [("requests", total), ("visitors", visitors)]
    rows.extend((c, by_status.get(c, 0.0)) for c in ("2xx", "3xx", "4xx", "5xx"))
    rows.extend((c, exact.get(c, 0.0)) for c in ("404", "403", "401"))
    rows.extend((m, by_method.get(m, 0.0)) for m in ("GET", "POST"))
    traffic = bars(rows, scale=total)
    # first two rows aren't shares, so no bar
    for row in traffic[:2]:
        row["pct"] = 0

    return {
        "window": w,
        "countries": countries,
        "agents": agents,
        "hosts": hosts,
        "traffic": traffic,
        "available": bool(countries or agents or hosts),
    }


def storage():
    """Fullest real filesystems; tmpfs and nfs excluded."""
    real = ('fstype!~"tmpfs|ramfs|overlay|squashfs|nfs.*|fuse.*|autofs",'
            'mountpoint!~"/nix/store|/run.*|/var/lib/docker.*|/var/lib/containers.*"')
    rows = promql(
        f'topk({DISK_ROWS}, 100 * (1 - node_filesystem_avail_bytes{{{real}}}'
        f' / node_filesystem_size_bytes{{{real}}}))')
    free = promql(f'sum(node_filesystem_avail_bytes{{{real}}})')

    out = []
    for r in rows:
        m = r["metric"]
        try:
            pct = round(float(r["value"][1]))
        except (TypeError, ValueError):
            continue
        out.append({
            "vm": m.get("vm", "?"),
            "mount": m.get("mountpoint", "?"),
            "pct": percent_clamp(pct),
        })
    return {"top": out, "free_total": human_size(scalar(free))}


def qb_session():
    """Log in with the generated password; works beyond the whitelist."""
    try:
        with open(os.path.join(TOKENS, "qbittorrent-user.token")) as f:
            user = f.read().strip()
        with open(os.path.join(TOKENS, "qbittorrent-pass.token")) as f:
            password = f.read().strip()
    except OSError as e:
        feed_io.log(f"no qBittorrent credentials: {e}")
        return None

    # this guest is on qBittorrent's bypass_auth_subnet_whitelist (112-internal-qbittorrent/main.nix)
    try:
        req = urllib.request.Request(QBITTORRENT + "/api/v2/app/version")
        with urllib.request.urlopen(req, timeout=QBITTORRENT_TIMEOUT_S) as r:
            if r.status == 200:
                return ""
    except (urllib.error.URLError, socket.timeout):
        pass

    data = urllib.parse.urlencode({"username": user, "password": password}).encode()
    req = urllib.request.Request(
        QBITTORRENT + "/api/v2/auth/login", data=data,
        headers={"Referer": QBITTORRENT})
    try:
        with urllib.request.urlopen(req, timeout=QBITTORRENT_TIMEOUT_S) as r:
            cookie = r.headers.get("Set-Cookie", "")
            if r.read().strip() != b"Ok.":
                feed_io.log("qBittorrent rejected the login")
                return None
    except (urllib.error.URLError, socket.timeout) as e:
        feed_io.log(f"qBittorrent login failed: {e}")
        return None
    return cookie.split(";")[0] if cookie else ""


def qb_get(path, cookie):
    req = urllib.request.Request(QBITTORRENT + path, headers={"Cookie": cookie})
    try:
        with urllib.request.urlopen(req, timeout=QBITTORRENT_TIMEOUT_S) as r:
            return json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        feed_io.log(f"qBittorrent {path} failed: {e}")
        return None


def torrents():
    empty = {"available": False, "dl": "0B/s", "ul": "0B/s",
             "downloading": 0, "seeding": 0, "paused": 0, "total": 0, "items": []}
    cookie = qb_session()
    if cookie is None:
        return empty

    transfer = qb_get("/api/v2/transfer/info", cookie) or {}
    listing = qb_get("/api/v2/torrents/info", cookie)
    if listing is None:
        return empty

    def bucket(state):
        if state in DOWNLOADING:
            return "downloading"
        if state in SEEDING:
            return "seeding"
        if state in PAUSED:
            return "paused"
        return "other"

    counts = {"downloading": 0, "seeding": 0, "paused": 0, "other": 0}
    for t in listing:
        counts[bucket(t.get("state", ""))] += 1

    # active downloads first, fastest first
    active = sorted(
        (t for t in listing if bucket(t.get("state", "")) == "downloading"),
        key=lambda t: (t.get("dlspeed", 0), t.get("progress", 0)), reverse=True)
    # unfinished only; finished torrents are noise
    rest = sorted((t for t in listing if float(t.get("progress", 0)) < 1),
                  key=lambda t: t.get("added_on", 0), reverse=True)
    ordered = active + [t for t in rest if t not in active]

    items = []
    for t in ordered[:TORRENT_ROWS]:
        pct = round(float(t.get("progress", 0)) * PERCENT)
        name = t.get("name", "?") if TORRENT_NAMES else (t.get("category") or "torrent")
        # scene and magnet-only names overflow a line
        if len(name) > NAME_CHARS:
            name = name[:NAME_CHARS - 1].rstrip() + "\u2026"
        items.append({
            "name": name,
            "pct": pct,
            "state": bucket(t.get("state", "")),
            "speed": human_rate(t.get("dlspeed", 0)),
            "size": human_size(t.get("size", 0)),
            "eta": eta(t.get("eta", 0), pct),
        })

    return {
        "available": True,
        "dl": human_rate(transfer.get("dl_info_speed", 0)),
        "ul": human_rate(transfer.get("up_info_speed", 0)),
        "downloading": counts["downloading"],
        "seeding": counts["seeding"],
        "paused": counts["paused"],
        "total": len(listing),
        "items": items,
    }


def main():
    if len(sys.argv) != 2 or not all((PROMETHEUS, LOKI, QBITTORRENT, INVENTORY, TOKENS, CLIENT_INGRESS, EDGE_ADDRESS)):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out_dir = sys.argv[1]

    rows, summary = services()
    # grid shows enabled vms; disabled ones as names
    running = [r for r in rows if not r["disabled"]]
    switched_off = [r["name"] for r in rows if r["disabled"]]
    net = network()
    tor = torrents()
    disks = storage()
    load = totals()
    reqs = requests()
    who = clients()

    now = datetime.now(timezone.utc).astimezone()
    payload = {
        "view": "stats",
        "generated_at": now.isoformat(),
        "label": now.strftime("%a %d %b %H:%M"),
        "summary": summary,
        "services": running[:SERVICE_ROWS],
        "services_more": max(0, len(running) - SERVICE_ROWS),
        "services_off": switched_off,
        "network": net,
        "totals": load,
        "requests": reqs,
        "clients": who,
        "storage": disks,
        "torrents": tor,
    }

    os.makedirs(out_dir, exist_ok=True)
    feed_io.file_write_atomic(os.path.join(out_dir, "stats.json"), json.dumps(payload, indent=2))
    print(f"{summary['up']}/{summary['total']} up, cpu {load['cpu_pct']}%, "
          f"mem {load['mem_used']}/{load['mem_total']}, {len(reqs)} busy routes, "
          f"{tor['total']} torrents, rx {net['rx']} tx {net['tx']}, "
          f"{len(who['countries'])} countries calling")
    return 0


if __name__ == "__main__":
    sys.exit(main())
