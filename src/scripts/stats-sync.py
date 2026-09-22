"""Build the TRMNL homelab dashboard payload.

Runs on vm-104. Prometheus is on vm-105. The qBittorrent credentials come
from the shared homepage-tokens mount and 10.100.0.104 is on that app's API
whitelist, so the dashboard needs nothing else opened up.

Writes <out-dir>/<token>/stats.json, which nginx serves and the TRMNL cloud
polls. The token is the only thing protecting it, exactly like the calendar
feed: the device cannot log in.
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROMETHEUS = os.environ.get("STATS_PROMETHEUS", "http://10.100.0.105:9090")
LOKI = os.environ.get("STATS_LOKI", "http://10.100.0.105:3100")
QBITTORRENT = os.environ.get("STATS_QBITTORRENT", "http://10.100.0.112")
INVENTORY = os.environ.get("STATS_INVENTORY", "/var/lib/homelab-stats/inventory.json")
TOKENS = os.environ.get("STATS_TOKENS", "/var/lib/homepage-tokens")
# how many rows the screen can hold before the rest is summarised. Four
# columns of thirteen, which is every declared VM with three slots spare: the
# router is the last entry by id, so a tighter budget cut the one host whose
# state matters most.
SERVICE_ROWS = int(os.environ.get("STATS_SERVICE_ROWS", "52"))
TORRENT_ROWS = int(os.environ.get("STATS_TORRENT_ROWS", "3"))
# The three side panels share 347px. Sending more rows than a panel can draw
# does not show more, it clips the last one in half, so each list is cut to
# what its panel holds: 17px a line for the two flat lists, 36px a torrent.
REQUEST_ROWS = int(os.environ.get("STATS_REQUEST_ROWS", "5"))
DISK_ROWS = int(os.environ.get("STATS_DISK_ROWS", "3"))
# longest torrent name the panel can hold on one line
NAME_CHARS = int(os.environ.get("STATS_NAME_CHARS", "42"))
# The "who is calling" strip. Only the external ingress is counted: vm-200
# relays into vm-100, so a request off the internet is logged by both and
# summing the two double-counts it. A day's window, because an hour of a
# private lab is mostly whatever the owner happened to open.
CLIENT_INGRESS = os.environ.get("STATS_CLIENT_INGRESS", "vm-200")
CLIENT_WINDOW = os.environ.get("STATS_CLIENT_WINDOW", "24h")
CLIENT_ROWS = int(os.environ.get("STATS_CLIENT_ROWS", "4"))
# public suffix to drop from hostnames, which are all under one domain
CLIENT_DOMAIN = os.environ.get("STATS_CLIENT_DOMAIN", ".lsck0.dev")
TIMEOUT = 8


def promql(query):
    """One instant query. Returns [] rather than raising: a dashboard with a
    missing panel beats a dashboard that never updates."""
    url = PROMETHEUS + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            body = json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"prometheus query failed ({query[:40]}...): {e}", file=sys.stderr)
        return []
    if body.get("status") != "success":
        return []
    return body["data"]["result"]


def by_instance(results):
    """instance label -> float. Stale targets from earlier VM numbering are
    still in the series database, so keep the newest sample per instance."""
    out = {}
    for r in results:
        inst = r["metric"].get("instance")
        if not inst:
            continue
        try:
            out[inst] = float(r["value"][1])
        except (TypeError, ValueError):
            continue
    return out


def human_rate(bytes_per_s):
    v = float(bytes_per_s)
    for unit in ("B", "K", "M", "G"):
        if v < 1024 or unit == "G":
            return f"{v:.0f}{unit}/s" if v >= 10 or unit == "B" else f"{v:.1f}{unit}/s"
        v /= 1024
    return f"{v:.0f}G/s"


def human_size(num):
    v = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.0f}{unit}" if v >= 10 or unit == "B" else f"{v:.1f}{unit}"
        v /= 1024
    return f"{v:.0f}TB"


def scrape_instance(vm):
    """The address Prometheus scrapes this VM on.

    For a VM that is its inventory address. The router's inventory address is
    its WAN side, 192.168.178.x, which nothing scrapes: node-exporter is only
    reached on the two LAN legs. Grafana's relabelling already special-cases
    the same pair. Without this the dashboard called the router down whatever
    it was doing.
    """
    if vm.get("type") == "router":
        return "10.100.0.1:9100"
    return f"{vm['ip']}:9100"


def services():
    """One row per declared VM, whatever state it is in - the same rule the
    Homepage dashboard follows. A VM that is meant to be running and is not is
    the single most useful thing on the screen, so it must not vanish."""
    try:
        with open(INVENTORY) as f:
            inv = json.load(f)
    except (OSError, ValueError) as e:
        print(f"no inventory ({e}); falling back to whatever Prometheus knows", file=sys.stderr)
        inv = {}

    up = by_instance(promql('up{job="homelab-node-exporter"}'))
    cpu = by_instance(promql(
        '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'))
    mem = by_instance(promql(
        '(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100'))

    # strip the "134-internal-" prefix the inventory carries, and where that
    # leaves two VMs called the same thing - the two Traefiks - put the id
    # back, or the grid shows one name twice and says nothing about which is
    # which. Grafana's relabelling solves the same collision with the zone,
    # but a quarter column has no room for "traefik-external".
    short = {k: v["name"].split("-", 2)[-1] for k, v in inv.items()}
    taken = {}
    for n in short.values():
        taken[n] = taken.get(n, 0) + 1

    rows = []
    for vmid, vm in sorted(inv.items(), key=lambda kv: int(kv[0])):
        inst = scrape_instance(vm)
        enabled = vm.get("enabled", "true")
        name = short[vmid]
        if taken[name] > 1:
            name = f"{name} {vmid}"
        online = up.get(inst, 0) >= 1
        rows.append({
            "vmid": vmid,
            "name": name,
            "online": online,
            "disabled": enabled == "false",
            "on_demand": enabled == "onDemand",
            "cpu": round(cpu.get(inst, 0.0), 1) if online else 0.0,
            "mem": round(mem.get(inst, 0.0), 1) if online else 0.0,
            # the template draws a bar from these, so clamp here rather than
            # emitting a width over 100%
            "cpu_pct": min(100, max(0, round(cpu.get(inst, 0.0)))) if online else 0,
            "mem_pct": min(100, max(0, round(mem.get(inst, 0.0)))) if online else 0,
        })

    expected = [r for r in rows if not r["disabled"]]
    return rows, {
        "up": sum(1 for r in expected if r["online"]),
        "total": len(expected),
        "down": [r["name"] for r in expected if not r["online"] and not r["on_demand"]],
    }


def network():
    """Lab-wide throughput, and the busiest hosts. Virtual devices are excluded
    or container bridges would double-count every byte."""
    real = 'device!~"lo|veth.*|docker.*|podman.*|br-.*|cni.*|tailscale.*|wg.*"'
    rx = promql(f'sum(rate(node_network_receive_bytes_total{{{real}}}[5m]))')
    tx = promql(f'sum(rate(node_network_transmit_bytes_total{{{real}}}[5m]))')
    top = promql(
        f'topk(4, sum by (vm) ('
        f'rate(node_network_receive_bytes_total{{{real}}}[5m])'
        f' + rate(node_network_transmit_bytes_total{{{real}}}[5m])))')

    def scalar(res):
        return float(res[0]["value"][1]) if res else 0.0

    return {
        "rx": human_rate(scalar(rx)),
        "tx": human_rate(scalar(tx)),
        "top": [{
            "vm": r["metric"].get("vm", "?"),
            "rate": human_rate(float(r["value"][1])),
        } for r in top],
    }


def totals():
    """CPU and memory of the machine that actually has them.

    Summing the guests was nonsense: 44 VMs add up to 108 vCPUs and 107GB on a
    box with 12 cores and 32GB, because virtual CPUs and guest RAM are
    oversubscribed by design. The host's own node_exporter is the only place
    the real figures exist.
    """
    host = os.environ.get("STATS_HOST_VM", "proxmox")
    sel = f'{{vm="{host}"}}'
    idle = f'{{vm="{host}",mode="idle"}}'

    def scalar(res, default=0.0):
        try:
            return float(res[0]["value"][1])
        except (IndexError, KeyError, TypeError, ValueError):
            return default

    busy = scalar(promql(
        f'100 * (1 - (sum(rate(node_cpu_seconds_total{idle}[5m]))'
        f' / sum(rate(node_cpu_seconds_total{sel}[5m]))))'))
    cores = scalar(promql(f'count(count by (cpu) (node_cpu_seconds_total{sel}))'))
    mem_total = scalar(promql(f'node_memory_MemTotal_bytes{sel}'))
    mem_free = scalar(promql(f'node_memory_MemAvailable_bytes{sel}'))
    used = mem_total - mem_free

    return {
        "cpu_pct": min(100, max(0, round(busy))),
        "cores": int(cores),
        "mem_pct": round(used / mem_total * 100) if mem_total else 0,
        "mem_used": human_size(used),
        "mem_total": human_size(mem_total),
    }


def requests():
    """Requests per minute per route, and which side of the house they came in
    on. Traefik reports the router and the instance that served it, so
    10.100.0.100 is a request that arrived over the LAN or the Headscale mesh
    and 10.200.0.200 is one relayed in off the internet. There is no client
    address in these metrics, so that split is as far as "from where" goes."""
    rows = promql('sum by (router, instance) (rate(traefik_router_requests_total[15m]))')
    by_router = {}
    for r in rows:
        name = r["metric"].get("router", "")
        if not name:
            continue
        # "forgejo-tls@file" is the router; the suffixes are Traefik's own
        name = name.split("@")[0]
        for suffix in ("-tls", "-relay", "-block"):
            if name.endswith(suffix):
                name = name[: -len(suffix)]
        try:
            rpm = float(r["value"][1]) * 60
        except (TypeError, ValueError):
            continue
        external = r["metric"].get("instance", "").startswith("10.200.")
        e = by_router.setdefault(name, {"name": name, "int": 0.0, "ext": 0.0})
        e["ext" if external else "int"] += rpm

    out = []
    for e in by_router.values():
        total = e["int"] + e["ext"]
        if total < 0.05:
            continue
        out.append({
            "name": e["name"],
            "rpm": f"{total:.1f}" if total < 10 else f"{total:.0f}",
            # where it came from, in one word, rather than two more columns
            "origin": "ext" if e["ext"] > e["int"] else ("int" if e["int"] else "ext"),
            "mixed": e["int"] > 0 and e["ext"] > 0,
        })
    out.sort(key=lambda x: float(x["rpm"]), reverse=True)
    return out[:REQUEST_ROWS]


# Traefik logs the User-Agent verbatim, which is thousands of distinct strings
# and useless as a series label, so Loki folds it into a family before the
# count. Order matters: Edge and Chrome both claim Safari, and Edge claims
# Chrome, so the most specific test comes first. `contains` rather than a
# regex because this Loki has no regexMatch:
#   invalid template for label 'agent': function "regexMatch" not defined
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


def logql(query):
    """One instant query against Loki. Same contract as promql: the dashboard
    loses a panel rather than an update."""
    url = LOKI + "/loki/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            body = json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"loki query failed ({query[:40]}...): {e}", file=sys.stderr)
        return []
    if body.get("status") != "success":
        return []
    return body["data"]["result"]


def human_count(n):
    if n < 1000:
        return str(int(n))
    if n < 10000:
        return f"{n / 1000:.1f}k"
    if n < 1000000:
        return f"{n / 1000:.0f}k"
    return f"{n / 1000000:.1f}M"


def ranked(results, label, fallback="?"):
    """Loki vector -> the label's value and a rounded count, largest first."""
    out = []
    for r in results:
        try:
            out.append((r["metric"].get(label) or fallback, float(r["value"][1])))
        except (KeyError, TypeError, ValueError):
            continue
    out.sort(key=lambda kv: -kv[1])
    return [{"name": n, "count": human_count(c)} for n, c in out[:CLIENT_ROWS]]


def clients():
    """Who reached the lab from the internet over the last day: which country
    Cloudflare says they were in, what they were running, and what they asked
    for. The Prometheus metrics carry no client detail at all, so this comes
    from the JSON access log that promtail already ships to Loki."""
    sel = f'{{job="traefik-access", host="{CLIENT_INGRESS}"}}'
    w = CLIENT_WINDOW
    k = CLIENT_ROWS

    # a request with no Cf-Ipcountry did not come through Cloudflare, which in
    # practice means someone dialled the address directly - a port scanner, or
    # a health check from inside the DMZ.
    countries = ranked(
        logql(f'topk({k}, sum by (country) (count_over_time({sel}[{w}])))'),
        "country", "direct")
    agents = ranked(
        logql(f'topk({k}, sum by (agent) (count_over_time({sel}'
              f' | json ua=`["request_User-Agent"]`'
              f' | label_format agent=`{AGENT_FAMILY}` [{w}])))'),
        "agent", "other")
    hosts = ranked(
        logql(f'topk({k}, sum by (h) (count_over_time({sel}'
              f' | json h="RequestHost" [{w}])))'),
        "h", "direct")
    for h in hosts:
        if h["name"].endswith(CLIENT_DOMAIN):
            h["name"] = h["name"][: -len(CLIENT_DOMAIN)]
        elif h["name"][:1].isdigit():
            # a bare address in the Host header is a scanner, not a visitor
            h["name"] = "by address"

    return {
        "window": w,
        "countries": countries,
        "agents": agents,
        "hosts": hosts,
        "available": bool(countries or agents or hosts),
    }


def storage():
    """The fullest real filesystems in the lab. Virtual and network mounts are
    excluded: tmpfs is RAM, and an NFS mount would report the NAS once per
    client that has it mounted."""
    real = ('fstype!~"tmpfs|ramfs|overlay|squashfs|nfs.*|fuse.*|autofs",'
            'mountpoint!~"/nix/store|/run.*|/var/lib/docker.*|/var/lib/containers.*"')
    rows = promql(
        f'topk({DISK_ROWS}, 100 * (1 - node_filesystem_avail_bytes{{{real}}}'
        f' / node_filesystem_size_bytes{{{real}}}))')
    free = by_instance(promql(f'node_filesystem_avail_bytes{{{real}}}'))

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
            "pct": min(100, max(0, pct)),
        })
    return {"top": out, "free_total": human_size(sum(free.values()))}


def qb_session():
    """Sign in with the generated password the *arr stack also uses, rather
    than relying on the subnet whitelist: the whitelist skips the login for
    the API, but a session works from anywhere the port is reachable."""
    try:
        with open(os.path.join(TOKENS, "qbittorrent-user.token")) as f:
            user = f.read().strip()
        with open(os.path.join(TOKENS, "qbittorrent-pass.token")) as f:
            password = f.read().strip()
    except OSError as e:
        print(f"no qBittorrent credentials: {e}", file=sys.stderr)
        return None

    # 10.100.0.104 is on qBittorrent's bypass_auth_subnet_whitelist, so the API
    # usually answers with no session at all. Only fall back to a login when it
    # does not, which keeps this working if the whitelist is ever trimmed.
    try:
        req = urllib.request.Request(QBITTORRENT + "/api/v2/app/version")
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            if r.status == 200:
                return ""
    except (urllib.error.URLError, socket.timeout):
        pass

    data = urllib.parse.urlencode({"username": user, "password": password}).encode()
    req = urllib.request.Request(
        QBITTORRENT + "/api/v2/auth/login", data=data,
        headers={"Referer": QBITTORRENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            cookie = r.headers.get("Set-Cookie", "")
            if r.read().strip() != b"Ok.":
                print("qBittorrent rejected the login", file=sys.stderr)
                return None
    except (urllib.error.URLError, socket.timeout) as e:
        print(f"qBittorrent login failed: {e}", file=sys.stderr)
        return None
    return cookie.split(";")[0] if cookie else ""


def qb_get(path, cookie):
    req = urllib.request.Request(QBITTORRENT + path, headers={"Cookie": cookie})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"qBittorrent {path} failed: {e}", file=sys.stderr)
        return None


# qBittorrent has a dozen states; the screen only needs the distinction
DOWNLOADING = {"downloading", "metaDL", "stalledDL", "queuedDL", "forcedDL", "checkingDL"}
SEEDING = {"uploading", "stalledUP", "queuedUP", "forcedUP", "checkingUP"}
PAUSED = {"pausedDL", "pausedUP", "stoppedDL", "stoppedUP"}


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

    # active downloads first, fastest first: that is what someone glances at.
    # Progress breaks the tie, because the queue only lets one torrent run at
    # a time, so everything behind it sits at 0B/s and the panel would
    # otherwise lead with three untouched magnets.
    active = sorted(
        (t for t in listing if bucket(t.get("state", "")) == "downloading"),
        key=lambda t: (t.get("dlspeed", 0), t.get("progress", 0)), reverse=True)
    rest = sorted(listing, key=lambda t: t.get("added_on", 0), reverse=True)
    ordered = active + [t for t in rest if t not in active]

    items = []
    for t in ordered[:TORRENT_ROWS]:
        pct = round(float(t.get("progress", 0)) * 100)
        name = t.get("name", "?")
        # scene releases run past 80 characters and a magnet-only torrent is a
        # 40-character hash. CSS ellipsis needs every ancestor to agree to
        # shrink, which is one silent failure away from a name running off the
        # panel, so cut it here as well.
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


def eta(seconds, pct):
    # qBittorrent reports 8640000 for "no estimate"
    if pct >= 100:
        return "done"
    if not seconds or seconds >= 8640000:
        return ""
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 2:
        print("usage: stats-sync.py <out-dir>", file=sys.stderr)
        return 2
    out_dir = sys.argv[1]

    rows, summary = services()
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
        "services": rows[:SERVICE_ROWS],
        "services_more": max(0, len(rows) - SERVICE_ROWS),
        "network": net,
        "totals": load,
        "requests": reqs,
        "clients": who,
        "storage": disks,
        "torrents": tor,
    }

    os.makedirs(out_dir, exist_ok=True)
    write_atomic(os.path.join(out_dir, "stats.json"), json.dumps(payload, indent=2))
    print(f"{summary['up']}/{summary['total']} up, cpu {load['cpu_pct']}%, "
          f"mem {load['mem_used']}/{load['mem_total']}, {len(reqs)} busy routes, "
          f"{tor['total']} torrents, rx {net['rx']} tx {net['tx']}, "
          f"{len(who['countries'])} countries calling")
    return 0


if __name__ == "__main__":
    sys.exit(main())
