"""The deploy controller's one door (vm-140): CI asks for a redeploy, the ingresses wake and stop idle apps.

Usage: controller-api.py <config.json>   (systemd socket activation, Accept=yes: the connection is fd 0)

    POST /redeploy/<app>   Authorization: Bearer <the app's token>   starts app-builder@<app>
    POST /wake/<app>       from a waker, for an app with idle         starts swarm-idle-wake@<app>
    POST /sleep/<app>      from a waker, for an app with idle         starts swarm-idle-sleep@<app>
    GET  /state/<app>      from a waker, for an app with idle         "running" or "stopped"

It only ever starts one of those units (polkit allows this user nothing else), takes no payload, and answers
202 started, 401 wrong token, 403 not a waker, 404 no such app or action, 405, 413 a body, 429 asked too often.
A redeploy while one runs coalesces into it: starting an active unit starts nothing. Every token is compared in
constant time; an unknown app answers 404 before any token is read, so the answer names no app's token.

Config keys: apps { <app>: { tokenFile (null on a guest's own swarm: redeploys are the controller's); idle } }, wakers [ip] (the ingresses, the state worker), redeployIntervalS, stateDir, stoppedDir, units
{ redeploy; wake; sleep } (unit templates, "%s" the app).
"""
import hmac
import json
import os
import re
import socket
import subprocess
import sys
import time

# ---- constants ----------------------------------------------------------------------------------

HEAD_BYTES_MAX = 8192
READ_TIMEOUT_S = 5
APP_NAME = re.compile(r"[a-z][a-z0-9-]*")
PATH = re.compile(r"/(redeploy|wake|sleep|state)/([^/]+)")
BEARER = "Bearer "
REASONS = {200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
           405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests"}
METHODS = {"redeploy": "POST", "wake": "POST", "sleep": "POST", "state": "GET"}


# ---- functions ----------------------------------------------------------------------------------

def respond(config, method, path, headers, remote, now_s, start_unit):
    """(status, body) for one request; start_unit(name) is the only effect besides the redeploy stamp."""
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
        with open(stamp, "w", encoding="utf-8"):
            pass
        start_unit(config["units"]["redeploy"] % app)
        return 202, "redeploy started\n"
    if remote not in config["wakers"]:
        return 403, "the ingresses and the state worker only\n"
    if not spec["idle"]:
        return 404, "the app never idles\n"
    if action == "state":
        return 200, "stopped\n" if os.path.exists(os.path.join(config["stoppedDir"], app)) else "running\n"
    start_unit(config["units"][action] % app)
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
    subprocess.run(["systemctl", "start", "--no-block", name], check=True)


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
