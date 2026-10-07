"""The relay's tenant map (lib/relay-tenants.py) against a fake docker api on a unix socket.

Usage: relay_tenants_test.py <relay-tenants.py>

Table cases for the map (an app's container, a foreign stack, the node's own container, an endpoint without an
address), and the daemon's life: the map written once the event stream is open, rewritten on an event that changes
it, left alone on one that does not, and the process ending when docker closes the stream.
"""
import importlib.util
import json
import os
import socketserver
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler

spec = importlib.util.spec_from_file_location("relay_tenants", sys.argv.pop(1))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

TENANTS = {"quiet": "app-quiet", "noisy": "app-noisy"}


def container(cid, stack):
    return {"Id": cid, "Labels": {relay.STACK_LABEL: stack} if stack else {}}


def endpoint(address):
    return {"Name": "gateway_x", "IPv4Address": f"{address}/16" if address else ""}


class Render(unittest.TestCase):
    def test_cases(self):
        network = {"Containers": {
            "a1": endpoint("172.18.0.5"),
            "b2": endpoint("172.18.0.3"),
            "c3": endpoint("172.18.0.9"),
            "d4": endpoint("172.18.0.7"),
            "e5": endpoint(None),
            "ingress-sbox": endpoint("172.18.0.2"),
        }}
        containers = [container("a1", "quiet"), container("b2", "noisy"), container("c3", "stranger"),
                      container("d4", None), container("e5", "quiet")]
        self.assertEqual(relay.tenants_render(network, containers, TENANTS),
                         "172.18.0.3 app-noisy;\n172.18.0.5 app-quiet;\n")

    def test_no_network_answer_is_an_empty_map(self):
        self.assertEqual(relay.tenants_render({"Containers": None}, [], TENANTS), "")

    def test_write_only_on_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "tenants.conf")
            self.assertTrue(relay.tenants_write(path, "a;\n"))
            self.assertFalse(relay.tenants_write(path, "a;\n"))
            self.assertTrue(relay.tenants_write(path, "b;\n"))
            self.assertEqual(sorted(os.listdir(tmp)), ["tenants.conf"])


class FakeDocker:
    """The three GETs the map makes; /events applies each queued change once the map read the state before it, then
    reports it, and closes after the last."""

    # a refresh reads the network and the container list
    GETS_PER_REFRESH = 2
    WAIT_S = 10

    def __init__(self, network, containers, steps):
        self.network, self.containers, self.steps = network, containers, steps
        self.paths = []
        self.read = threading.Condition()

    def refreshes(self):
        return sum(1 for p in self.paths if not p.startswith("/events")) // self.GETS_PER_REFRESH

    def handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def answer(self, body):
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                with fake.read:
                    fake.paths.append(self.path)
                    fake.read.notify_all()
                if self.path.startswith(f"/networks/{relay.GATEWAY_NETWORK}"):
                    return self.answer(fake.network)
                if self.path.startswith("/containers/json"):
                    return self.answer(fake.containers)
                if self.path.startswith("/events"):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.flush()
                    for done, change in enumerate(fake.steps, start=1):
                        with fake.read:
                            assert fake.read.wait_for(lambda: fake.refreshes() >= done, fake.WAIT_S), fake.paths
                        change(fake)
                        self.wfile.write(b'{"Type":"container","Action":"start"}\n')
                        self.wfile.flush()
                    with fake.read:
                        assert fake.read.wait_for(lambda: fake.refreshes() > len(fake.steps), fake.WAIT_S), fake.paths
                    return None
                self.send_error(403)
                return None
        return Handler


class Daemon(unittest.TestCase):
    def test_map_follows_the_events_and_the_process_ends_with_the_stream(self):
        written = []

        def add_noisy(fake):
            fake.network["Containers"]["b2"] = endpoint("172.18.0.3")
            fake.containers.append(container("b2", "noisy"))

        def unrelated(fake):
            fake.containers.append(container("x9", "stranger"))

        fake = FakeDocker({"Containers": {"a1": endpoint("172.18.0.5")}}, [container("a1", "quiet")], [add_noisy, unrelated])
        with tempfile.TemporaryDirectory() as tmp:
            socket_path, out = os.path.join(tmp, "docker.sock"), os.path.join(tmp, "tenants.conf")
            server = socketserver.ThreadingUnixStreamServer(socket_path, fake.handler())
            threading.Thread(target=server.serve_forever, daemon=True).start()
            original = relay.tenants_write
            relay.tenants_write = lambda path, text: written.append(text) or original(path, text)
            sys.argv = ["relay-tenants", socket_path, out, json.dumps(TENANTS)]
            try:
                self.assertEqual(relay.main(), 1)
            finally:
                relay.tenants_write = original
                server.shutdown()
                server.server_close()
            with open(out) as handle:
                final = handle.read()
        self.assertEqual(written[0], "172.18.0.5 app-quiet;\n")
        self.assertEqual(final, "172.18.0.3 app-noisy;\n172.18.0.5 app-quiet;\n")
        self.assertEqual(len(written), 3)
        self.assertTrue(fake.paths[0].startswith("/events"), fake.paths)


if __name__ == "__main__":
    unittest.main()
