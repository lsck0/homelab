"""The deploy controller's door (lib/controller-api.py), request by request: who may start what.

Usage: controller_api_test.py <path to controller-api.py>
"""
import importlib.util
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("controller_api", sys.argv.pop(1))
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

TOKENS = {"demo": "a" * 64, "other": "b" * 64}
INGRESS = "10.200.0.200"
STRANGER = "203.0.113.9"
INTERVAL_S = 60
NOW_S = 1_000_000.0


# -----------------------------------------------------------------------------
# TESTS
# -----------------------------------------------------------------------------

class Door(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        for name in ("state", "stopped"):
            os.mkdir(os.path.join(root, name))
        apps = {}
        for app, token in TOKENS.items():
            with open(os.path.join(root, app), "w", encoding="utf-8") as f:
                f.write(token + "\n")
            apps[app] = {"tokenFile": os.path.join(root, app), "idle": app == "demo"}
        self.config = {"apps": apps, "wakers": [INGRESS], "redeployIntervalS": INTERVAL_S,
                       "stateDir": os.path.join(root, "state"), "stoppedDir": os.path.join(root, "stopped"),
                       "units": {"redeploy": "app-builder@%s.service", "wake": "swarm-idle-wake@%s.service",
                                 "sleep": "swarm-idle-sleep@%s.service"}}
        self.started = []

    def tearDown(self):
        self.dir.cleanup()

    def ask(self, method, path, token=None, remote=STRANGER, now_s=NOW_S, headers=None):
        h = dict(headers or {})
        if token is not None:
            h["authorization"] = f"Bearer {token}"
        return api.respond(self.config, method, path, h, remote, now_s, self.started.append)[0]

    def test_redeploy_table(self):
        # (method, path, token) -> status; nothing but the valid case starts a unit
        for method, path, token, status in [
            ("POST", "/redeploy/demo", None, 401),
            ("POST", "/redeploy/demo", "", 401),
            ("POST", "/redeploy/demo", TOKENS["other"], 401),
            ("POST", "/redeploy/demo", TOKENS["demo"][:-1], 401),
            ("POST", "/redeploy/nope", TOKENS["demo"], 404),
            ("POST", "/redeploy/../demo", TOKENS["demo"], 404),
            ("GET", "/redeploy/demo", TOKENS["demo"], 405),
            ("POST", "/deploy/demo", TOKENS["demo"], 404),
        ]:
            with self.subTest(method=method, path=path, token=token):
                self.assertEqual(self.ask(method, path, token), status)
        self.assertEqual(self.started, [])
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 202)
        self.assertEqual(self.started, ["app-builder@demo.service"])

    def test_a_guest_swarm_takes_no_redeploy(self):
        self.config["apps"]["demo"]["tokenFile"] = None
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 404)
        self.assertEqual(self.started, [])

    def test_a_burst_is_one_redeploy(self):
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 202)
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"], now_s=NOW_S + 1), 429)
        # each app has its own window
        self.assertEqual(self.ask("POST", "/redeploy/other", TOKENS["other"], now_s=NOW_S + 1), 202)
        self.assertEqual(self.started, ["app-builder@demo.service", "app-builder@other.service"])

    def test_the_window_is_measured_from_the_last_start(self):
        stamp = os.path.join(self.config["stateDir"], "demo")
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 202)
        os.utime(stamp, (NOW_S - INTERVAL_S, NOW_S - INTERVAL_S))
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 202)

    def test_no_payload(self):
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"], headers={"content-length": "12"}), 413)
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"], headers={"content-length": "x"}), 400)
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"], headers={"content-length": "0"}), 202)

    def test_idle_actions_only_from_an_ingress_and_only_for_idle_apps(self):
        for method, path, remote, status in [
            ("POST", "/wake/demo", STRANGER, 403),
            ("POST", "/wake/other", INGRESS, 404),
            ("POST", "/wake/demo", INGRESS, 202),
            ("POST", "/sleep/demo", INGRESS, 202),
            ("GET", "/wake/demo", INGRESS, 405),
        ]:
            with self.subTest(path=path, remote=remote):
                self.assertEqual(self.ask(method, path, remote=remote), status)
        self.assertEqual(self.started, ["swarm-idle-wake@demo.service", "swarm-idle-sleep@demo.service"])

    def test_state(self):
        def respond():
            return api.respond(self.config, "GET", "/state/demo", {}, INGRESS, NOW_S, self.started.append)

        self.assertEqual(respond(), (200, "running\n"))
        open(os.path.join(self.config["stoppedDir"], "demo"), "w").close()
        self.assertEqual(respond(), (200, "stopped\n"))
        self.assertEqual(self.started, [])


class Wire(unittest.TestCase):
    def read(self, data):
        import socket
        a, b = socket.socketpair()
        a.sendall(data)
        a.close()
        try:
            return api.request_read(b)
        finally:
            b.close()

    def test_a_request_parses(self):
        self.assertEqual(self.read(b"POST /redeploy/demo HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n\r\n"),
                         ("POST", "/redeploy/demo", {"host": "x", "authorization": "Bearer t"}))

    def test_malformed_and_oversized_are_refused(self):
        for data in (b"GET /\r\n\r\n", b"GET / HTTP/1.1\r\nnocolon\r\n\r\n", b"GET / HTTP/1.1\r\n",
                     b"GET / HTTP/1.1\r\nX: " + b"a" * api.HEAD_BYTES_MAX + b"\r\n\r\n"):
            with self.subTest(data=data[:40]):
                self.assertIsNone(self.read(data))


if __name__ == "__main__":
    unittest.main(verbosity=1)
