"""The deploy controller's one door (vm-107): CI asks for a redeploy, the ingresses wake and stop idle apps.

Usage: controller-api.py <config.json>   (systemd socket activation, Accept=yes: the connection is fd 0)

    POST /redeploy/<app>   Authorization: Bearer <the app's token>   starts app-builder@<app>
    POST /wake/<app>       from a waker, for an app with idle         starts swarm-idle-wake@<app>
    POST /sleep/<app>      from a waker, for an app with idle         starts swarm-idle-sleep@<app>
    GET  /state/<app>      from a waker, for an app with idle         "running" or "stopped"
    GET  /uptime/<app>     from a waker, for an app with idle         seconds since its last wake

It only ever starts one of those units (polkit allows this user nothing else) and takes no payload. A redeploy
while one runs coalesces into it, and counts against the window only once its unit started. An unknown app answers
404 before any token is read, so the answer names no app's token.
"""
import hmac
import json
import os
import re
import socket
import subprocess
import sys
import time

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

HEAD_BYTES_MAX = 8192
READ_TIMEOUT_S = 5
# --no-block only queues the job
UNIT_START_TIMEOUT_S = 3
APP_NAME = re.compile(r"[a-z][a-z0-9-]*")
PATH = re.compile(r"/(redeploy|wake|sleep|state|uptime)/([^/]+)")
BEARER = "Bearer "
REASONS = {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
           405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"}
METHODS = {"redeploy": "POST", "wake": "POST", "sleep": "POST", "state": "GET", "uptime": "GET"}


# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

def respond(config, method, path, headers, remote, now_s, start_unit):
    """(status, body) for one request; start_unit(name) -> started is the only effect besides the redeploy stamp."""
    match = PATH.fullmatch(path)
    if not match:
        return 404, "no such action\n"
    action, app = match.groups()
    if method != METHODS[action]:
        return 405, f"{METHODS[action]} only\n"
    length = headers.get("content-length", "0")
    if not length.isdigit():
        return 400, "bad content-length\n"
    if int(length) > 0:
        return 413, "no payload\n"
    spec = config["apps"].get(app) if APP_NAME.fullmatch(app) else None
    if spec is None:
        return 404, "no such app\n"
    if action == "redeploy":
        if spec["tokenFile"] is None:
            return 404, "redeploys go to the deploy controller\n"
        with open(spec["tokenFile"], encoding="utf-8") as f:
            token = f.read().strip()
        offered = headers.get("authorization", "")
        if not (offered.startswith(BEARER) and hmac.compare_digest(offered[len(BEARER):].encode(), token.encode())):
            return 401, "wrong token\n"
        stamp = os.path.join(config["stateDir"], app)
        if os.path.exists(stamp) and now_s - os.path.getmtime(stamp) < config["redeployIntervalS"]:
            return 429, f"one redeploy per {config['redeployIntervalS']}s\n"
        if not start_unit(config["units"]["redeploy"] % app):
            return 503, "the redeploy did not start\n"
        with open(stamp, "w", encoding="utf-8"):
            pass
        return 202, "redeploy started\n"
    if remote not in config["wakers"]:
        return 403, "the ingresses and the state worker only\n"
    if not spec["idle"]:
        return 404, "the app never idles\n"
    if action == "state":
        return 200, "stopped\n" if os.path.exists(os.path.join(config["stoppedDir"], app)) else "running\n"
    if action == "uptime":
        woke = os.path.join(config["stoppedDir"], app + config["wokeSuffix"])
        # never woken through the controller: up since its deploy, as old as the epoch to the reaper
        woke_s = os.path.getmtime(woke) if os.path.exists(woke) else 0
        return 200, f"{int(now_s - woke_s)}\n"
    if not start_unit(config["units"][action] % app):
        return 503, f"the {action} did not start\n"
    return 202, f"{action} started\n"


def request_read(conn):
    """Method, path and lowercased headers of one request, or None when it is malformed or too large."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(HEAD_BYTES_MAX)
        if not chunk or len(data) + len(chunk) > HEAD_BYTES_MAX:
            return None
        data += chunk
    lines = data.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3:
        return None
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(":")
        if not sep:
            return None
        headers[key.strip().lower()] = value.strip()
    return parts[0], parts[1], headers


def unit_start(name):
    try:
        return subprocess.run(["systemctl", "start", "--no-block", name], check=False,
                              timeout=UNIT_START_TIMEOUT_S).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    conn = socket.socket(fileno=sys.stdin.fileno())
    conn.settimeout(READ_TIMEOUT_S)
    try:
        request = request_read(conn)
    except (OSError, UnicodeDecodeError):
        request = None
    if request is None:
        status, body = 400, "bad request\n"
    else:
        status, body = respond(config, *request, os.environ.get("REMOTE_ADDR", ""), time.time(), unit_start)
    print(f"controller-api: {request[0] + ' ' + request[1] if request else '-'} -> {status}", file=sys.stderr)
    conn.sendall(f"HTTP/1.1 {status} {REASONS[status]}\r\nContent-Type: text/plain\r\nContent-Length: {len(body)}\r\n"
                 f"Connection: close\r\n\r\n{body}".encode())
    return 0


if __name__ == "__main__":
    sys.exit(main())
