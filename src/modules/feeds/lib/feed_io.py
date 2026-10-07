"""The feed scripts' I/O: atomic writes, JSON files, and JSON over HTTP from Prometheus and Loki.

Used by scripts/{energy-sync,stats-sync,calendar-sync,spot-price}.py. Nothing here raises on an operating error:
a failed call logs one line and returns None, an empty answer returns [], so a caller can tell "unreachable"
(print "-") from "nothing there" (print 0). `urlopen` is a parameter so tests can inject failures.

Overview:
    file_write_atomic(path, data)                  str or bytes, through a temporary file and a rename
    file_json_load(path)                           the parsed file, or None
    json_dumps(value)                              the feeds' JSON text
    http_json(url, timeout_s, data, urlopen)       GET, or POST of a form when data is given
    prometheus_query(base, query, at_s, urlopen)   instant vector rows, [] when empty, None on failure
    prometheus_query_range(base, query, start_s, end_s, step_s, urlopen)
    loki_query(base, query, urlopen)               instant vector rows, same contract

Example:
    rows = prometheus_query("http://10.100.0.105:9090", "up")
    if rows is None:
        ...  # prometheus unreachable
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request

# a query of the feeds touches at most a month of one-minute samples; prometheus answers those in about a second
HTTP_TIMEOUT_S = 15
# a log line names the call, not its whole query
LOG_QUERY_CHARS = 60


def log(message):
    print(message, file=sys.stderr, flush=True)


def file_write_atomic(path, data):
    """Write through a temporary file, so a reader never sees half a file."""
    tmp = f"{path}.tmp"
    with open(tmp, "wb" if isinstance(data, bytes) else "w") as handle:
        handle.write(data)
    os.replace(tmp, path)


def json_dumps(value):
    """The feeds' JSON: indented for a reader with curl, unicode kept for the German labels."""
    return json.dumps(value, indent=2, ensure_ascii=False)


def file_json_load(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def http_json(url, timeout_s=HTTP_TIMEOUT_S, data=None, urlopen=urllib.request.urlopen):
    """The parsed JSON answer, or None; data (a dict) is sent as a form POST, which has no URL length limit."""
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    try:
        with urlopen(urllib.request.Request(url, data=body), timeout=timeout_s) as response:
            return json.load(response)
    except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError, OSError) as e:
        log(f"{url.split('?')[0]}: {e}")
        return None


def prometheus_result(body, what):
    if not isinstance(body, dict) or body.get("status") != "success":
        if body is not None:
            log(f"prometheus refused {what[:LOG_QUERY_CHARS]}: {body.get('error') if isinstance(body, dict) else body}")
        return None
    result = body.get("data", {}).get("result")
    return result if isinstance(result, list) else None


def prometheus_query(base, query, at_s=None, urlopen=urllib.request.urlopen):
    """Instant vector rows {"metric", "value"}; [] when empty, None when prometheus failed."""
    form = {"query": query}
    if at_s is not None:
        form["time"] = f"{at_s:.3f}"
    return prometheus_result(http_json(f"{base}/api/v1/query", data=form, urlopen=urlopen), query)


def prometheus_query_range(base, query, start_s, end_s, step_s, urlopen=urllib.request.urlopen):
    """Range matrix rows {"metric", "values"}; [] when empty, None when prometheus failed."""
    form = {"query": query, "start": f"{start_s:.3f}", "end": f"{end_s:.3f}", "step": str(step_s)}
    return prometheus_result(http_json(f"{base}/api/v1/query_range", data=form, urlopen=urlopen), query)


def loki_query(base, query, urlopen=urllib.request.urlopen):
    """Loki instant query rows; same contract as prometheus_query."""
    url = f"{base}/loki/api/v1/query?" + urllib.parse.urlencode({"query": query})
    return prometheus_result(http_json(url, urlopen=urlopen), query)
