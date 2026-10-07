"""The telemetry relay's tenant map: each app container on this node by its docker_gwbridge address.

Usage: relay-tenants.py <docker socket> <tenants.conf> <tenants json>

<tenants json> maps a stack (the app) to its tenant; containers of any other stack, and the node's own, map to
nothing, so the relay refuses them. <tenants.conf> is the body of nginx's `geo` block, "<address> <tenant>;" per
line, rewritten (atomically, only when it changed) at start and on every container start or death the docker api
reports. A task reaches its node's relay through docker_gwbridge, the network every swarm task leaves by, so its
address there is what nginx sees. The docker api is the read-only proxy's (modules/app-telemetry): no write is
possible from here.

Overview:
    docker_get(socket_path, path)                    the parsed answer of one GET
    tenants_render(network, containers, tenants)     the geo lines from the api's answers, sorted
    tenants_write(path, text)                        True when the file changed
    events_follow(socket_path, on_event)             returns when the stream ends or fails
"""
import http.client
import json
import os
import socket
import sys
import urllib.parse

# every swarm task's way out of its overlay networks, and so into the node
GATEWAY_NETWORK = "docker_gwbridge"
STACK_LABEL = "com.docker.stack.namespace"
# what changes the map: a container getting or losing its gateway address
EVENTS = {"type": ["container"], "event": ["start", "die"]}
# a docker api answer on the node itself
REQUEST_TIMEOUT_S = 10


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, timeout_s):
        super().__init__("localhost", timeout=timeout_s)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


def log(message):
    print(message, file=sys.stderr, flush=True)


def docker_get(socket_path, path):
    connection = UnixConnection(socket_path, REQUEST_TIMEOUT_S)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        if response.status != http.client.OK:
            raise OSError(f"GET {path}: {response.status} {body[:200]!r}")
        return json.loads(body)
    finally:
        connection.close()


def tenants_render(network, containers, tenants):
    """'<address> <tenant>;' for every container of a known stack on the gateway network, sorted by address."""
    stack_of = {c["Id"]: (c.get("Labels") or {}).get(STACK_LABEL) for c in containers}
    lines = []
    for container_id, endpoint in (network.get("Containers") or {}).items():
        tenant = tenants.get(stack_of.get(container_id))
        address = (endpoint.get("IPv4Address") or "").split("/")[0]
        if tenant and address:
            lines.append((address, tenant))
    return "".join(f"{address} {tenant};\n" for address, tenant in sorted(lines))


def tenants_write(path, text):
    try:
        with open(path) as handle:
            if handle.read() == text:
                return False
    except OSError:
        pass
    tmp = f"{path}.tmp"
    with open(tmp, "w") as handle:
        handle.write(text)
    os.replace(tmp, path)
    return True


def tenants_refresh(socket_path, out_path, tenants):
    network = docker_get(socket_path, f"/networks/{GATEWAY_NETWORK}")
    filters = urllib.parse.quote(json.dumps({"label": [STACK_LABEL]}))
    containers = docker_get(socket_path, f"/containers/json?filters={filters}")
    text = tenants_render(network, containers, tenants)
    if tenants_write(out_path, text):
        log(f"relay tenants: {text.count(chr(10))} containers")


def events_follow(socket_path, on_event):
    """Calls on_event once the stream is open, then for every event; returns when docker closes the stream."""
    connection = UnixConnection(socket_path, None)
    try:
        connection.request("GET", "/events?filters=" + urllib.parse.quote(json.dumps(EVENTS)))
        response = connection.getresponse()
        if response.status != http.client.OK:
            raise OSError(f"GET /events: {response.status}")
        # opened first: a container starting meanwhile is in the stream, never between refresh and stream
        on_event()
        for line in response:
            if line.strip():
                on_event()
    finally:
        connection.close()


def main():
    if len(sys.argv) != 4:
        log(__doc__.split("\n\n")[1])
        return 2
    socket_path, out_path, tenants = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
    # a failure ends the process: systemd restarts it with a growing delay, the map stays as it was meanwhile
    events_follow(socket_path, lambda: tenants_refresh(socket_path, out_path, tenants))
    log("docker closed the event stream")
    return 1


if __name__ == "__main__":
    sys.exit(main())
