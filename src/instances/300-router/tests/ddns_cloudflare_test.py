"""lib/ddns-cloudflare.sh against a fake ipify and cloudflare api with injected faults (tests/ddns-cloudflare.nix).

The fake keeps a record table and logs every call; a case sets the public address, seeds records, arms faults
(the k-th call matching a method and path prefix answers an error status) and runs the real script. The oracle is
the contract in the script's header: records converge to one per name with the address and proxy flag asked for,
the address is recorded as synced only when every record converged, and an unchanged synced address costs no api
call.
"""

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.parse

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

ZONE = "lsck0.dev"
ZONE_ID = "zone-1"
TOKEN = "test-token"
ADDRESS_OLD = "198.51.100.1"
ADDRESS_NEW = "198.51.100.2"
SCRIPT = os.environ["DDNS_SCRIPT"]
RECORDS = [
    {"name": f"grafana.{ZONE}", "proxied": True},
    {"name": f"share.{ZONE}", "proxied": False},
    {"name": f"*.{ZONE}", "proxied": False},
]

# -----------------------------------------------------------------------------
# FAKE API
# -----------------------------------------------------------------------------


class Fake:
    def __init__(self):
        self.address = ADDRESS_OLD
        self.records = {}
        self.next_id = 0
        self.calls = []
        # [{"method", "prefix", "skip", "status"}]: the call after `skip` matching ones fails once
        self.faults = []

    def record_add(self, name, content, proxied):
        self.next_id += 1
        record_id = f"r{self.next_id}"
        self.records[record_id] = {"id": record_id, "type": "A", "name": name, "content": content, "proxied": proxied}
        return record_id

    def fault_take(self, method, path):
        for fault in self.faults:
            if fault["method"] == method and path.startswith(fault["prefix"]):
                if fault["skip"] > 0:
                    fault["skip"] -= 1
                    continue
                self.faults.remove(fault)
                return fault["status"]
        return None


FAKE = Fake()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode() if not isinstance(body, str) else body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        FAKE.calls.append({"method": method, "path": url.path, "query": query, "body": body,
                           "auth": self.headers.get("Authorization")})
        if url.path == "/ip":
            return self.reply(200, FAKE.address)
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.reply(403, {"success": False, "errors": ["bad token"]})
        status = FAKE.fault_take(method, url.path)
        if status is not None:
            return self.reply(status, {"success": False, "errors": ["injected"]})
        records_path = f"/zones/{ZONE_ID}/dns_records"
        if method == "GET" and url.path == "/zones":
            return self.reply(200, {"success": True, "result": [{"id": ZONE_ID}] if query.get("name") == ZONE else []})
        if method == "GET" and url.path == records_path:
            found = [r for r in FAKE.records.values() if r["name"] == query.get("name") and r["type"] == query.get("type")]
            return self.reply(200, {"success": True, "result": found})
        if method == "POST" and url.path == records_path:
            record_id = FAKE.record_add(body["name"], body["content"], body["proxied"])
            return self.reply(200, {"success": True, "result": FAKE.records[record_id]})
        if url.path.startswith(records_path + "/"):
            record_id = url.path.rsplit("/", 1)[1]
            if record_id not in FAKE.records:
                return self.reply(404, {"success": False, "errors": ["no record"]})
            if method == "PUT":
                FAKE.records[record_id].update(content=body["content"], proxied=body["proxied"], name=body["name"])
                return self.reply(200, {"success": True, "result": FAKE.records[record_id]})
            if method == "DELETE":
                del FAKE.records[record_id]
                return self.reply(200, {"success": True, "result": {"id": record_id}})
        return self.reply(404, {"success": False, "errors": ["no route"]})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


# -----------------------------------------------------------------------------
# HARNESS
# -----------------------------------------------------------------------------


def run(env_base):
    """Run the script once; returns (exit code, the api calls it made)."""
    FAKE.calls = []
    result = subprocess.run(["bash", SCRIPT], env=env_base, capture_output=True, text=True,
                            cwd=env_base["DDNS_CWD"])
    sys.stdout.write(result.stdout + result.stderr)
    return result.returncode, [c for c in FAKE.calls if c["path"] != "/ip"]


def converged(address):
    """Every record name holds exactly one record with the address and its proxy flag."""
    for want in RECORDS:
        have = [r for r in FAKE.records.values() if r["name"] == want["name"]]
        if len(have) != 1 or have[0]["content"] != address or have[0]["proxied"] != want["proxied"]:
            return False
    return True


def synced(env_base):
    path = os.path.join(env_base["DDNS_STATE_DIR"], "ip")
    return open(path).read() if os.path.exists(path) else None


def fault_arm(method, prefix, status, skip=0):
    FAKE.faults.append({"method": method, "prefix": prefix, "skip": skip, "status": status})


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    work = tempfile.mkdtemp()
    with open(os.path.join(work, "records.json"), "w") as f:
        json.dump(RECORDS, f)
    with open(os.path.join(work, "token"), "w") as f:
        f.write(TOKEN)
    os.makedirs(os.path.join(work, "state"))
    # a file a glob of "*.lsck0.dev" would expand to: the script must never glob a record name
    cwd = os.path.join(work, "cwd")
    os.makedirs(cwd)
    open(os.path.join(cwd, f"decoy.{ZONE}"), "w").close()
    env = dict(os.environ, DDNS_RECORDS=os.path.join(work, "records.json"), DDNS_ZONE=ZONE,
               DDNS_TOKEN_FILE=os.path.join(work, "token"), DDNS_STATE_DIR=os.path.join(work, "state"),
               DDNS_IP_URL=f"{base}/ip", DDNS_API_URL=base, DDNS_CWD=cwd)

    print("case: a fresh zone gets one record per name")
    code, calls = run(env)
    assert code == 0 and converged(ADDRESS_OLD) and synced(env) == ADDRESS_OLD, (code, FAKE.records)
    assert not any(r["name"] == f"decoy.{ZONE}" for r in FAKE.records.values()), "a record name was globbed"
    assert all(c["auth"] == f"Bearer {TOKEN}" for c in calls)

    print("case: an unchanged, freshly synced address costs no api call")
    code, calls = run(env)
    assert code == 0 and calls == [], calls

    print("case: a changed address is put to every record, and only once")
    FAKE.address = ADDRESS_NEW
    code, calls = run(env)
    assert code == 0 and converged(ADDRESS_NEW) and synced(env) == ADDRESS_NEW
    assert sorted(c["method"] for c in calls if c["method"] != "GET") == ["PUT"] * len(RECORDS), calls

    print("case: matching records, proxied or not, are left alone on a resync")
    os.utime(os.path.join(env["DDNS_STATE_DIR"], "ip"), (0, 0))
    code, calls = run(env)
    assert code == 0 and [c for c in calls if c["method"] != "GET"] == [], calls

    print("case: a failed zone lookup changes nothing and records nothing")
    FAKE.address = ADDRESS_OLD
    fault_arm("GET", "/zones", 500)
    code, calls = run(env)
    assert code != 0 and synced(env) == ADDRESS_NEW and converged(ADDRESS_NEW), (code, calls)

    print("case: a failed record lookup is no missing record: nothing is created")
    fault_arm("GET", f"/zones/{ZONE_ID}/dns_records", 429)
    code, calls = run(env)
    assert code != 0 and synced(env) == ADDRESS_NEW, code
    assert not any(c["method"] == "POST" for c in calls), calls
    assert len(FAKE.records) == len(RECORDS), FAKE.records

    print("case: the next run retries what failed and converges")
    code, calls = run(env)
    assert code == 0 and converged(ADDRESS_OLD) and synced(env) == ADDRESS_OLD, (code, FAKE.records)

    print("case: a failed put leaves the address unsynced, the next run puts it")
    FAKE.address = ADDRESS_NEW
    fault_arm("PUT", f"/zones/{ZONE_ID}/dns_records/", 500, skip=1)
    code, calls = run(env)
    assert code != 0 and synced(env) == ADDRESS_OLD and not converged(ADDRESS_NEW), code
    code, calls = run(env)
    assert code == 0 and converged(ADDRESS_NEW) and synced(env) == ADDRESS_NEW, code

    print("case: duplicate records of a name are deleted down to one")
    FAKE.record_add(f"grafana.{ZONE}", ADDRESS_OLD, True)
    os.utime(os.path.join(env["DDNS_STATE_DIR"], "ip"), (0, 0))
    code, calls = run(env)
    assert code == 0 and converged(ADDRESS_NEW), FAKE.records
    assert [c["method"] for c in calls].count("DELETE") == 1, calls

    print("case: an ip service answering garbage is no address")
    FAKE.address = "<html>rate limited</html>"
    os.utime(os.path.join(env["DDNS_STATE_DIR"], "ip"), (0, 0))
    code, calls = run(env)
    assert code != 0 and calls == [] and synced(env) == ADDRESS_NEW, (code, calls)

    print("ddns-cloudflare: all cases passed")
    server.shutdown()


if __name__ == "__main__":
    main()
