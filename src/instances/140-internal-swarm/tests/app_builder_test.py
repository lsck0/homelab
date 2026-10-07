"""The builder's stack handling (lib/app-builder.py): which file, which builds, which environment, table by table.

Usage: app_builder_test.py <path to app-builder.py>
"""
import importlib.util
import os
import sys
import tempfile
import unittest

import yaml

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("app_builder", sys.argv.pop(1))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

HINT = {"context": ".", "dockerfile": "Dockerfile", "target": None, "args": {}}


def write(root, path, text):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as f:
        f.write(text)


class Stack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_named_stack_wins(self):
        write(self.repo, "compose.yaml", "services: {a: {image: x}}")
        write(self.repo, "deploy/stack.yaml", "services: {b: {image: y}}")
        stack, stack_dir = builder.stack_load({"stack": "deploy/stack.yaml"}, self.repo)
        self.assertEqual(list(stack["services"]), ["b"])
        self.assertEqual(stack_dir, os.path.join(self.repo, "deploy"))

    def test_conventions_in_order(self):
        write(self.repo, "docker-compose.yml", "services: {late: {image: x}}")
        write(self.repo, "compose.yaml", "services: {early: {image: y}}")
        stack, _ = builder.stack_load({"stack": None}, self.repo)
        self.assertEqual(list(stack["services"]), ["early"])

    def test_no_compose_file_is_one_image(self):
        stack, stack_dir = builder.stack_load({"stack": None}, self.repo)
        self.assertEqual(stack, {"services": {"web": {"build": "."}}})
        self.assertEqual(stack_dir, self.repo)

    def test_broken_stack_is_an_operating_error(self):
        for text in ["services: [1, 2]", "a: [", "- just a list"]:
            with self.subTest(text=text):
                write(self.repo, "compose.yaml", text)
                with self.assertRaises(builder.BuildError):
                    builder.stack_load({"stack": None}, self.repo)

    def test_catalog_build_hint_is_repo_relative(self):
        build = builder.build_resolve(
            {"image": "wat/server:latest"},
            dict(HINT, context="services/server", dockerfile="services/server/prod.Dockerfile", target="prod"),
            os.path.join(self.repo, "infrastructure"), self.repo)
        self.assertEqual(build["context"], os.path.join(self.repo, "services/server"))
        self.assertEqual(build["dockerfile"], os.path.join(self.repo, "services/server/prod.Dockerfile"))
        self.assertEqual(build["target"], "prod")

    def test_compose_build_is_stack_relative(self):
        stack_dir = os.path.join(self.repo, "deploy")
        build = builder.build_resolve(
            {"build": {"context": "..", "dockerfile": "app.Dockerfile", "args": ["A=1"], "target": "prod"}},
            None, stack_dir, self.repo)
        self.assertEqual(os.path.normpath(build["context"]), self.repo)
        self.assertEqual(os.path.normpath(build["dockerfile"]), os.path.join(self.repo, "app.Dockerfile"))
        self.assertEqual(build["args"], {"A": "1"})
        self.assertEqual(build["target"], "prod")

    def test_unknown_build_keys_are_refused(self):
        for key, value in [("dockerfile_inline", "FROM scratch"), ("secrets", ["x"]), ("ssh", ["default"]),
                           ("network", "host"), ("cache_from", ["x"])]:
            with self.subTest(key=key):
                with self.assertRaises(builder.BuildError):
                    builder.build_resolve({"build": {"context": ".", key: value}}, None, self.repo, self.repo)

    def test_image_only_service_is_not_built(self):
        self.assertIsNone(builder.build_resolve({"image": "redis:8"}, None, self.repo, self.repo))

    def test_env_files_inline_escaped_and_environment_wins(self):
        write(self.repo, "env/prod.env",
              "# comment\nA=1\nB='two'\nexport C=3\nPASSWORD=CHANGE_ME\nHASH=$2y$x\nN=v # note\nQ=\"a\\nb\"\n")
        svc = {"env_file": ["./env/prod.env"], "environment": {"B": "override", "D": None}}
        builder.env_inline(svc, self.repo, self.repo)
        self.assertNotIn("env_file", svc)
        self.assertEqual(svc["environment"], {"A": "1", "B": "override", "C": "3", "PASSWORD": "CHANGE_ME",
                                              "HASH": "$$2y$$x", "N": "v", "Q": "a\nb", "D": ""})

    def test_optional_env_file(self):
        svc = {"env_file": [{"path": "missing.env", "required": False}]}
        builder.env_inline(svc, self.repo, self.repo)
        self.assertNotIn("environment", svc)
        with self.assertRaises(builder.BuildError):
            builder.env_inline({"env_file": ["missing.env"]}, self.repo, self.repo)

    def test_environment_list_form(self):
        svc = {"environment": ["X=1", "Y"]}
        builder.env_inline(svc, self.repo, self.repo)
        self.assertEqual(svc["environment"], {"X": "1", "Y": ""})

    def test_nothing_outside_the_checkout(self):
        os.symlink("/run/secrets", os.path.join(self.repo, "leak"))
        for svc, hint in [({"build": {"context": "/run/secrets"}}, None),
                          ({"build": {"context": ".", "dockerfile": "../../etc/passwd"}}, None),
                          ({"build": {"context": "leak"}}, None),
                          ({"image": "x"}, dict(HINT, context="/run/secrets")),
                          ({"image": "x"}, dict(HINT, dockerfile="/etc/passwd"))]:
            with self.subTest(svc=svc, hint=hint):
                with self.assertRaises(builder.BuildError):
                    builder.build_resolve(svc, hint, self.repo, self.repo)
        for env_file in ["/run/secrets/app-deploy-key", "../../outside.env", "leak/app-deploy-key"]:
            with self.subTest(env_file=env_file):
                with self.assertRaises(builder.BuildError):
                    builder.env_inline({"env_file": [env_file]}, self.repo, self.repo)
        with self.assertRaises(builder.BuildError):
            builder.stack_load({"stack": "../../etc/hosts"}, self.repo)

    def test_metrics_render(self):
        empty = builder.STATE_EMPTY
        states = {
            "hello": dict(empty, head="h", sha="a", build_hash="x", deployed_at=1700000000, committed_at=1699999880,
                          built=1, reused=2),
            "wat": dict(empty, failure={"head": "h", "sha": "b", "build_hash": "x", "count": 3, "retry_at": 9}),
            "idle": dict(empty),
        }
        text = builder.metrics_render(states, 1700000500)
        self.assertIn("homelab_app_builder_last_run_timestamp_seconds 1700000500", text)
        self.assertIn('homelab_app_deploy_ok{app="hello"} 1', text)
        self.assertIn('homelab_app_deploy_ok{app="wat"} 0', text)
        self.assertIn('homelab_app_deploy_failures{app="wat"} 3', text)
        self.assertIn('homelab_app_deploy_last_success_timestamp_seconds{app="hello"} 1700000000', text)
        self.assertNotIn('last_success_timestamp_seconds{app="wat"}', text)
        self.assertIn('homelab_app_deploy_latency_seconds{app="hello"} 120', text)
        self.assertIn('homelab_app_images{app="hello",how="built"} 1', text)
        self.assertIn('homelab_app_images{app="hello",how="reused"} 2', text)
        self.assertNotIn('latency_seconds{app="wat"}', text)
        self.assertNotIn('app="idle"', text)

    def test_a_state_from_before_the_deploy_facts_loads(self):
        with tempfile.TemporaryDirectory() as state_dir:
            with open(os.path.join(state_dir, "hello.json"), "w", encoding="utf-8") as f:
                f.write('{"head": "h", "sha": "a", "build_hash": "x", "deployed_at": 1, "failure": null}')
            self.assertEqual(builder.state_load(state_dir, "hello")["committed_at"], None)

    def test_backoff_doubles_to_its_cap(self):
        ctx = {"backoff": {"baseS": 300, "maxS": 3600}}
        self.assertEqual([builder.backoff_s(ctx, n) for n in (1, 2, 3, 4, 5, 10 ** 6)],
                         [300, 600, 1200, 2400, 3600, 3600])


class Parallel(unittest.TestCase):
    def test_builds_run_side_by_side_and_bounded(self):
        import threading
        parallelism = 2
        services = {f"s{i}": {"build": "."} for i in range(2 * parallelism)}
        active, peak, lock = [0], [0], threading.Lock()
        # each build waits for a partner: a builder running them one by one breaks the barrier instead of passing
        together = threading.Barrier(parallelism, timeout=5)

        def build(ctx, app, name, build_, tag, labels, args):
            with lock:
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            together.wait()
            with lock:
                active[0] -= 1
            return f"r/{app}/{name}@sha256:{'0' * 64}"

        def checkout(ctx, repo, sha, into):
            write(into, "compose.yaml", yaml.safe_dump({"services": services}))
            write(into, "Dockerfile", "FROM scratch\n")
            return "2026-01-01T00:00:00+00:00"

        fakes = {"repo_checkout": checkout,
                 "git_object": lambda ctx, repo_dir, path: path, "registry_digest": lambda *a: None,
                 "registry_login": lambda ctx: None, "image_build_push": build, "stack_deploy": lambda *a: None,
                 "image_mark_live": lambda *a: None, "log": lambda *a: None, "dashboards_publish": lambda *a: None}
        saved = {name: getattr(builder, name) for name in fakes}
        for name, fake in fakes.items():
            setattr(builder, name, fake)
        try:
            ctx = {"registry": "r", "loggedIn": False, "buildParallelism": parallelism}
            spec_ = {"repo": "o/a", "stack": None, "build": {}, "exclude": [], "dashboards": [], "manager": None}
            facts = builder.app_build_deploy(ctx, "a", spec_, "c" * 40)
        finally:
            for name, real in saved.items():
                setattr(builder, name, real)
        self.assertEqual(peak[0], parallelism)
        self.assertEqual((facts["built"], facts["reused"]), (len(services), 0))


class Deploy(unittest.TestCase):
    def deploy(self, manager):
        calls = []
        saved = builder.process_run
        builder.process_run = lambda args, timeout_s, **kw: calls.append((args, kw.get("input")))
        try:
            with tempfile.TemporaryDirectory() as inbox:
                ctx = {"inbox": inbox, "deployUnit": "swarm-deploy@", "deployKeyFile": "/k",
                       "timeouts": {"deployS": 1, "sshConnectS": 1, "sshAliveIntervalS": 1, "sshAliveCountMax": 1}}
                builder.stack_deploy(ctx, "demo", manager, {"services": {"web": {"image": "x"}}})
                kept = sorted(os.listdir(inbox))
                if kept:
                    with open(os.path.join(inbox, kept[0]), encoding="utf-8") as f:
                        kept = f.read()
        finally:
            builder.process_run = saved
        return calls, kept

    def test_this_hosts_swarm_takes_the_stack_through_its_unit(self):
        calls, kept = self.deploy(None)
        self.assertEqual(calls, [(["systemctl", "start", "swarm-deploy@demo.service"], None)])
        self.assertIn("image: x", kept)

    def test_a_guest_swarm_takes_it_over_its_forced_command(self):
        calls, kept = self.deploy({"address": "10.100.0.170", "knownHosts": "/kh"})
        self.assertEqual(kept, [])
        (args, stdin), = calls
        self.assertEqual((args[0], args[-2:]), ("ssh", ["root@10.100.0.170", "demo"]))
        self.assertIn("image: x", stdin)


class ContentKey(unittest.TestCase):
    """The key that decides between a build and a reuse, over a real git checkout."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.ctx = {"timeouts": {"gitS": 30}}
        self.git("init", "-q")
        write(self.repo, "web/Dockerfile", "FROM scratch\nCOPY . /\n")
        write(self.repo, "web/index.html", "v1")
        write(self.repo, "README.md", "readme")
        self.commit()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        import subprocess
        subprocess.run(["git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "c")

    def key(self, args=None, target=None, dockerfile="web/Dockerfile"):
        build = {"context": os.path.join(self.repo, "web"), "dockerfile": os.path.join(self.repo, dockerfile),
                 "target": target, "args": {}}
        meta = {"GIT_COMMIT": "c1", "LAST_UPDATED": "d1"}
        return builder.content_key(self.ctx, self.repo, build, dict(meta, **(args or {})))

    def test_a_commit_outside_the_context_keeps_the_key(self):
        before = self.key()
        write(self.repo, "README.md", "changed")
        self.commit()
        self.assertEqual(self.key(), before)

    def test_the_context_the_target_and_the_args_change_it(self):
        before = self.key()
        self.assertNotEqual(self.key(target="prod"), before)
        self.assertNotEqual(self.key(args={"MODE": "x"}), before)
        write(self.repo, "web/index.html", "v2")
        self.commit()
        self.assertNotEqual(self.key(), before)

    def test_commit_metadata_counts_only_where_the_dockerfile_reads_it(self):
        before = self.key()
        self.assertEqual(self.key(args={"GIT_COMMIT": "c2"}), before)
        write(self.repo, "web/Dockerfile", "FROM scratch\nARG GIT_COMMIT\nCOPY . /\n")
        self.commit()
        declared = self.key()
        self.assertNotEqual(self.key(args={"GIT_COMMIT": "c2"}), declared)


if __name__ == "__main__":
    unittest.main()
