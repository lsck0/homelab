"""crowdsec-stub: CrowdSec's local api and appsec endpoints as the traefik bouncer plugin calls them, for tests.

Runs as the `crowdsec` container of modules/traefik in a test (lib/offline-traefik.nix swaps the image), so
the real bouncer plugin, the real container unit and its published ports are what the test exercises.

  local api, :8080   GET /v1/decisions?ip=<ip>: a ban for every address listed in the bans file, else null
  appsec, :7422 and :7423   403 {"action": "ban"} when the inspected request carries X-Test-Attack: 1, else 200

Bans: one address per line in /var/lib/crowdsec/data/stub-bans (the host's /var/lib/crowdsec/data, mounted),
read on every call. Every call is appended as a json line to /var/lib/crowdsec/data/stub-calls.jsonl:
{"api", "port", "method", "path", "ip", "attack", "verdict"}. /var/lib/crowdsec/data/stub-ready appears once every
port listens: the bouncer refuses every request until then, as it does while the real crowdsec starts.
"""

import http.server
import json
import socketserver
import sys
import threading
import urllib.parse

DATA_DIR = "/var/lib/crowdsec/data"
BANS_PATH = f"{DATA_DIR}/stub-bans"
CALLS_PATH = f"{DATA_DIR}/stub-calls.jsonl"
READY_PATH = f"{DATA_DIR}/stub-ready"
LAPI_PORT = 8080
APPSEC_PORTS = (7422, 7423)
ATTACK_HEADER = "X-Test-Attack"
# the address the plugin forwards with every appsec call
APPSEC_IP_HEADER = "X-Crowdsec-Appsec-Ip"
BAN_DURATION = "4h"
CALLS_LOCK = threading.Lock()


def bans_load():
    try:
        with open(BANS_PATH, encoding="utf-8") as f:
            return {line.strip() for line in f if line.strip()}
    except FileNotFoundError:
        return set()


def call_log(entry):
    with CALLS_LOCK, open(CALLS_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def lapi(self):
        url = urllib.parse.urlsplit(self.path)
        ip = urllib.parse.parse_qs(url.query).get("ip", [None])[0]
        banned = url.path == "/v1/decisions" and ip in bans_load()
        call_log({"api": "lapi", "port": LAPI_PORT, "method": self.command, "path": url.path, "ip": ip,
                  "attack": False, "verdict": "ban" if banned else "allow"})
        if not banned:
            self.reply(200, None)
            return
        self.reply(200, [{"id": 1, "origin": "cscli", "scenario": "homelab-test", "scope": "Ip", "type": "ban",
                          "value": ip, "duration": BAN_DURATION}])

    def appsec(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        attack = self.headers.get(ATTACK_HEADER) == "1"
        call_log({"api": "appsec", "port": self.server.server_address[1], "method": self.command, "path": self.path,
                  "ip": self.headers.get(APPSEC_IP_HEADER), "attack": attack, "verdict": "ban" if attack else "allow"})
        if attack:
            self.reply(403, {"action": "ban", "http_status": 403})
        else:
            self.reply(200, {"action": "allow", "http_status": 200})

    def handle_any(self):
        if self.server.server_address[1] == LAPI_PORT:
            self.lapi()
        else:
            self.appsec()

    do_GET = handle_any
    do_POST = handle_any
    do_HEAD = handle_any
    do_PUT = handle_any
    do_DELETE = handle_any

    def log_message(self, format, *args):
        sys.stderr.write("crowdsec-stub: " + (format % args) + "\n")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    servers = [Server(("0.0.0.0", port), Handler) for port in (LAPI_PORT, *APPSEC_PORTS)]
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    # bound sockets queue connections already, so the file can come before the first serve_forever
    open(READY_PATH, "w", encoding="utf-8").close()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
