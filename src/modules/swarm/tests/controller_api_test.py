"""The deploy controller's door (lib/controller-api.py), request by request: who may start what.

Usage: controller_api_test.py <path to controller-api.py>
"""

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True
API_PATH = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("controller_api", API_PATH)
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)

TOKENS = {"demo": "a" * 64, "other": "b" * 64}
INGRESS = "10.200.0.200"
STRANGER = "203.0.113.9"
INTERVAL_S = 60
NOW_S = 1_000_000.0
# far beyond any test's runtime: a read that hits it is a bug, not the clock
DEADLINE_FAR_S = 60
# a read budget of this much in the end-to-end request
READ_BUDGET_S = 0.3
DRIBBLE_LINES = 6


class Door(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        root = self.dir.name
        for name in ("state", "stopped", "deploys"):
            os.mkdir(os.path.join(root, name))
        apps = {}
        for app, token in TOKENS.items():
            with open(os.path.join(root, app), "w", encoding="utf-8") as f:
                f.write(token + "\n")
            apps[app] = {"tokenFile": os.path.join(root, app), "idle": app == "demo"}
        self.config = {
            "apps": apps,
            "wakers": [INGRESS],
            "redeployIntervalS": INTERVAL_S,
            "stateDir": os.path.join(root, "state"),
            "stoppedDir": os.path.join(root, "stopped"),
            "deployStatusDir": os.path.join(root, "deploys"),
            "wokeSuffix": ".woke",
            "units": {
                "redeploy": "app-builder@%s.service",
                "wake": "swarm-idle-wake@%s.service",
                "sleep": "swarm-idle-sleep@%s.service",
            },
        }
        self.started = []
        self.startable = True

    def start(self, unit):
        if self.startable:
            self.started.append(unit)
        return self.startable

    def tearDown(self):
        self.dir.cleanup()

    def ask(self, method, path, token=None, remote=STRANGER, now_s=NOW_S, headers=None):
        h = dict(headers or {})
        if token is not None:
            h["authorization"] = f"Bearer {token}"
        return api.respond(self.config, method, path, h, remote, now_s, self.start)[0]

    def test_deploy_status(self):
        def deploy(token):
            return api.respond(
                self.config, "GET", "/deploy/demo", {"authorization": f"Bearer {token}"}, STRANGER, NOW_S, self.start
            )

        self.assertEqual(deploy(TOKENS["demo"])[0], 404)
        record = {"sha": "c0ffee", "deployed_at": 1, "failure": None, "build_hash": "secret-ish", "head": "c0ffee"}
        with open(os.path.join(self.config["deployStatusDir"], "demo.json"), "w", encoding="utf-8") as f:
            json.dump(record, f)
        status, body = deploy(TOKENS["demo"])
        expected = {"sha": "c0ffee", "previous_sha": None, "deployed_at": 1, "failure": None, "hold": None}
        self.assertEqual((status, json.loads(body)), (200, expected))
        self.assertEqual(deploy(TOKENS["other"])[0], 401)
        self.assertEqual(self.ask("POST", "/deploy/demo", TOKENS["demo"]), 405)
        self.assertEqual(self.started, [])

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
            ("POST", "/build/demo", TOKENS["demo"], 404),
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

    def test_a_unit_that_does_not_start_is_503_and_no_stamp(self):
        self.startable = False
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"]), 503)
        self.assertEqual(self.ask("POST", "/wake/demo", remote=INGRESS), 503)
        self.assertFalse(os.path.exists(os.path.join(self.config["stateDir"], "demo")))
        # the retry is not rate limited by the failure
        self.startable = True
        self.assertEqual(self.ask("POST", "/redeploy/demo", TOKENS["demo"], now_s=NOW_S + 1), 202)

    def test_a_start_that_cannot_run_or_hangs_is_no_start(self):
        saved = api.subprocess.run
        for error in (OSError("no systemctl"), api.subprocess.TimeoutExpired("systemctl", api.UNIT_START_TIMEOUT_S)):

            def run(*args, error=error, **kwargs):
                raise error

            api.subprocess.run = run
            try:
                self.assertFalse(api.unit_start("app-builder@demo.service"))
            finally:
                api.subprocess.run = saved

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
            return api.respond(self.config, "GET", "/state/demo", {}, INGRESS, NOW_S, self.start)

        self.assertEqual(respond(), (200, "running\n"))
        open(os.path.join(self.config["stoppedDir"], "demo"), "w").close()
        self.assertEqual(respond(), (200, "stopped\n"))
        self.assertEqual(self.started, [])

    def test_uptime_counts_from_the_last_wake(self):
        def respond(remote=INGRESS):
            return api.respond(self.config, "GET", "/uptime/demo", {}, remote, NOW_S, self.start)

        self.assertEqual(respond(), (200, f"{int(NOW_S)}\n"))
        woke = os.path.join(self.config["stoppedDir"], "demo.woke")
        open(woke, "w").close()
        os.utime(woke, (NOW_S - 30, NOW_S - 30))
        self.assertEqual(respond(), (200, "30\n"))
        self.assertEqual(respond(STRANGER)[0], 403)
        self.assertEqual(self.ask("POST", "/uptime/demo", remote=INGRESS), 405)
        self.assertEqual(self.started, [])


class Wire(unittest.TestCase):
    def read(self, data):
        a, b = socket.socketpair()
        a.sendall(data)
        a.close()
        try:
            return api.request_read(b, time.monotonic() + DEADLINE_FAR_S)
        finally:
            b.close()

    def test_a_request_parses(self):
        self.assertEqual(
            self.read(b"POST /redeploy/demo HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\n\r\n"),
            ("POST", "/redeploy/demo", {"host": "x", "authorization": "Bearer t"}),
        )

    def test_malformed_and_oversized_are_refused(self):
        for data in (
            b"GET /\r\n\r\n",
            b"GET / HTTP/1.1\r\nnocolon\r\n\r\n",
            b"GET / HTTP/1.1\r\n",
            b"GET / HTTP/1.1\r\nX: " + b"a" * api.HEAD_BYTES_MAX + b"\r\n\r\n",
        ):
            with self.subTest(data=data[:40]):
                self.assertIsNone(self.read(data))

    def test_a_dribbled_head_times_out_at_its_deadline_not_per_chunk(self):
        a, b = socket.socketpair()

        # each line arrives well within the deadline, the head never completes
        def dribble():
            a.sendall(b"GET /state/demo HTTP/1.1\r\n")
            for _ in range(DRIBBLE_LINES):
                time.sleep(READ_BUDGET_S / DRIBBLE_LINES * 2)
                a.sendall(b"X: y\r\n")

        writer = threading.Thread(target=dribble)
        with a, b:
            deadline_s = time.monotonic() + READ_BUDGET_S
            writer.start()
            with self.assertRaises(TimeoutError):
                api.request_read(b, deadline_s)
            self.assertLess(time.monotonic() - deadline_s, READ_BUDGET_S)
            writer.join()

    def test_a_slow_client_is_answered_408_before_the_unit_is_killed(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as config:
            json.dump({"requestMaxS": api.UNIT_START_TIMEOUT_S + api.REPLY_MARGIN_S + READ_BUDGET_S}, config)
            config.flush()
            a, b = socket.socketpair()
            with a, b:
                a.sendall(b"GET /state/demo HTTP/1.1\r\n")
                start_s = time.monotonic()
                done = subprocess.run([sys.executable, API_PATH, config.name], stdin=b, capture_output=True, check=True)
                self.assertLess(time.monotonic() - start_s, api.UNIT_START_TIMEOUT_S + READ_BUDGET_S)
                self.assertTrue(a.recv(api.HEAD_BYTES_MAX).startswith(b"HTTP/1.1 408 Request Timeout\r\n"))
                self.assertIn(b"-> 408", done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
