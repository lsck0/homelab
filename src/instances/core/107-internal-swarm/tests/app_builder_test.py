"""The builder (lib/app-builder.py) table by table: its stack handling (which file, which builds, which environment),
the github credential's scope, a rollback's hold and a named run past the backoff.

Usage: app_builder_test.py <path to app-builder.py>
"""

import contextlib
import importlib.util
import os
import sys
import tempfile
import types
import unittest

import yaml

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("app_builder", sys.argv.pop(1))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

HINT = {"context": ".", "dockerfile": "Dockerfile", "target": None, "args": {}}
# modules/upstream's exit status for an outage
UNAVAILABLE = 75
UPSTREAMS = {
    "retry": {"attempts": 3, "backoffS": 5, "probeTimeoutS": 1},
    "unavailable": UNAVAILABLE,
    "registries": {"docker.io": "dockerhub", "ghcr.io": "ghcr"},
}


@contextlib.contextmanager
def patched(**fakes):
    """The builder's functions replaced by fakes for the block."""
    saved = {name: getattr(builder, name) for name in fakes}
    for name, fake in fakes.items():
        setattr(builder, name, fake)
    try:
        yield
    finally:
        for name, real in saved.items():
            setattr(builder, name, real)


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
            os.path.join(self.repo, "infrastructure"),
            self.repo,
        )
        self.assertEqual(build["context"], os.path.join(self.repo, "services/server"))
        self.assertEqual(build["dockerfile"], os.path.join(self.repo, "services/server/prod.Dockerfile"))
        self.assertEqual(build["target"], "prod")

    def test_compose_build_is_stack_relative(self):
        stack_dir = os.path.join(self.repo, "deploy")
        build = builder.build_resolve(
            {"build": {"context": "..", "dockerfile": "app.Dockerfile", "args": ["A=1"], "target": "prod"}},
            None,
            stack_dir,
            self.repo,
        )
        self.assertEqual(os.path.normpath(build["context"]), self.repo)
        self.assertEqual(os.path.normpath(build["dockerfile"]), os.path.join(self.repo, "app.Dockerfile"))
        self.assertEqual(build["args"], {"A": "1"})
        self.assertEqual(build["target"], "prod")

    def test_unknown_build_keys_are_refused(self):
        for key, value in [
            ("dockerfile_inline", "FROM scratch"),
            ("secrets", ["x"]),
            ("ssh", ["default"]),
            ("network", "host"),
            ("cache_from", ["x"]),
        ]:
            with self.subTest(key=key):
                with self.assertRaises(builder.BuildError):
                    builder.build_resolve({"build": {"context": ".", key: value}}, None, self.repo, self.repo)

    def test_image_only_service_is_not_built(self):
        self.assertIsNone(builder.build_resolve({"image": "redis:8"}, None, self.repo, self.repo))

    def test_env_files_inline_escaped_and_environment_wins(self):
        write(
            self.repo,
            "env/prod.env",
            "# comment\nA=1\nB='two'\nexport C=3\nPASSWORD=CHANGE_ME\nHASH=$2y$x\nN=v # note\nQ=\"a\\nb\"\n",
        )
        svc = {"env_file": ["./env/prod.env"], "environment": {"B": "override", "D": None}}
        builder.env_inline(svc, self.repo, self.repo)
        self.assertNotIn("env_file", svc)
        self.assertEqual(
            svc["environment"],
            {
                "A": "1",
                "B": "override",
                "C": "3",
                "PASSWORD": "CHANGE_ME",
                "HASH": "$$2y$$x",
                "N": "v",
                "Q": "a\nb",
                "D": "",
            },
        )

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
        for svc, hint in [
            ({"build": {"context": "/run/secrets"}}, None),
            ({"build": {"context": ".", "dockerfile": "../../etc/passwd"}}, None),
            ({"build": {"context": "leak"}}, None),
            ({"image": "x"}, dict(HINT, context="/run/secrets")),
            ({"image": "x"}, dict(HINT, dockerfile="/etc/passwd")),
        ]:
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
            "hello": dict(
                empty,
                head="h",
                sha="a",
                build_hash="x",
                deployed_at=1700000000,
                committed_at=1699999880,
                built=1,
                reused=2,
            ),
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
        self.assertIn('homelab_app_deployed_info{app="hello",sha="a",held="false"} 1', text)
        self.assertNotIn('deployed_info{app="wat"', text)
        self.assertNotIn('app="idle"', text)

    def test_a_state_from_before_the_deploy_facts_loads(self):
        with tempfile.TemporaryDirectory() as state_dir:
            with open(os.path.join(state_dir, "hello.json"), "w", encoding="utf-8") as f:
                f.write('{"head": "h", "sha": "a", "build_hash": "x", "deployed_at": 1, "failure": null}')
            self.assertEqual(builder.state_load(state_dir, "hello")["committed_at"], None)

    def test_backoff_doubles_to_its_cap(self):
        ctx = {"backoff": {"baseS": 300, "maxS": 3600}}
        self.assertEqual(
            [builder.backoff_s(ctx, n) for n in (1, 2, 3, 4, 5, 10**6)], [300, 600, 1200, 2400, 3600, 3600]
        )


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

        fakes = {
            "repo_checkout": checkout,
            "git_object": lambda ctx, repo_dir, path: path,
            "registry_digest": lambda *a: None,
            "registry_login": lambda ctx: None,
            "image_build_push": build,
            "cache_mounts_prune": lambda ctx: None,
            "stack_deploy": lambda *a: None,
            "image_mark_live": lambda *a: None,
            "log": lambda *a: None,
            "dashboards_publish": lambda *a: None,
        }
        saved = {name: getattr(builder, name) for name in fakes}
        for name, fake in fakes.items():
            setattr(builder, name, fake)
        try:
            ctx = {"registry": "r", "loggedIn": False, "buildParallelism": parallelism, "upstreams": UPSTREAMS}
            spec_ = {"repo": "o/a", "stack": None, "build": {}, "exclude": [], "dashboards": [], "manager": None}
            facts = builder.app_build_deploy(ctx, "a", spec_, "c" * 40)
        finally:
            for name, real in saved.items():
                setattr(builder, name, real)
        self.assertEqual(peak[0], parallelism)
        self.assertEqual((facts["built"], facts["reused"]), (len(services), 0))


class Locks(unittest.TestCase):
    """Each app's turn holds its own lock: a busy app delays nobody else."""

    def run_builder(self, state_dir, only):
        ran = []
        saved = builder.app_run
        builder.app_run = lambda ctx, app, spec_, state, requested: ran.append(app) or state
        try:
            code = builder.builder_run({"deployStatusDir": state_dir}, {"a": {}, "b": {}}, state_dir, only)
        finally:
            builder.app_run = saved
        return code, ran

    def test_the_timer_run_leaves_a_busy_app_to_the_run_at_it(self):
        with tempfile.TemporaryDirectory() as state_dir:
            held = builder.app_lock(state_dir, "a", wait=True)
            try:
                self.assertIsNone(builder.app_lock(state_dir, "a", wait=False))
                code, ran = self.run_builder(state_dir, None)
            finally:
                held.close()
            self.assertEqual((code, ran), (0, ["b"]))
            # positive control: free again, the timer's run takes both
            self.assertEqual(self.run_builder(state_dir, None), (0, ["a", "b"]))

    def test_a_run_for_one_app_looks_at_it_alone(self):
        with tempfile.TemporaryDirectory() as state_dir:
            self.assertEqual(self.run_builder(state_dir, "b"), (0, ["b"]))


class GithubCredential(unittest.TestCase):
    """git's own url matching decides where the token goes: the app's repo, nothing beside it."""

    def header_for(self, env, url):
        import subprocess

        found = subprocess.run(
            ["git", "config", "--get-urlmatch", "http.extraheader", url], env=env, capture_output=True, text=True
        )
        return found.stdout.strip()

    def test_the_token_reaches_the_apps_own_repo_alone(self):
        env = builder.git_env({"github": "https://github.com", "githubToken": "t0k"}, "lsck0/hello")
        self.assertTrue(self.header_for(env, "https://github.com/lsck0/hello").startswith("Authorization: Basic "))
        self.assertTrue(self.header_for(env, "https://github.com/lsck0/hello/info/refs"))
        for url in [
            "https://github.com/lsck0/private",
            "https://github.com/lsck0/hello-private",
            "https://github.com/",
        ]:
            with self.subTest(url=url):
                self.assertEqual(self.header_for(env, url), "")

    def test_no_token_sends_no_header(self):
        env = builder.git_env({"github": "https://github.com", "githubToken": None}, "lsck0/hello")
        self.assertEqual(self.header_for(env, "https://github.com/lsck0/hello"), "")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")


class Checks(unittest.TestCase):
    """requireChecks: a commit deploys once its check runs passed, waits while one runs, fails with a failed one."""

    CTX = {"baseRefreshS": 10**6, "upstreams": UPSTREAMS, "backoff": {"baseS": 300, "maxS": 3600}}
    SPEC = {"repo": "o/a", "branch": "main", "watch": [], "hash": "x", "requireChecks": True}

    def run_with(self, runs):
        deployed = []

        def build_deploy(ctx, app, spec_, sha):
            deployed.append(sha)
            return {"committed_at": 1, "built": 1, "reused": 0}

        with patched(
            branch_head=lambda ctx, repo, branch: "b",
            check_runs=lambda ctx, repo, sha: runs,
            app_build_deploy=build_deploy,
            time_now=lambda: 1000,
            log=lambda *a: None,
        ):
            state = builder.app_run(self.CTX, "a", self.SPEC, dict(builder.STATE_EMPTY), requested=False)
        return state, deployed

    def test_passed_checks_deploy(self):
        runs = [
            {"name": "test", "status": "completed", "conclusion": "success"},
            {"name": "lint", "status": "completed", "conclusion": "skipped"},
        ]
        state, deployed = self.run_with(runs)
        self.assertEqual((deployed, state["sha"], state["failure"]), (["b"], "b", None))

    def test_a_running_check_or_none_yet_waits_without_a_failure(self):
        for runs in ([], [{"name": "test", "status": "in_progress", "conclusion": None}]):
            with self.subTest(runs=runs):
                state, deployed = self.run_with(runs)
                self.assertEqual((deployed, state), ([], builder.STATE_EMPTY))

    def test_a_failed_check_is_the_commits_failure(self):
        state, deployed = self.run_with([{"name": "test", "status": "completed", "conclusion": "failure"}])
        self.assertEqual(deployed, [])
        self.assertEqual((state["failure"]["sha"], state["failure"]["count"]), ("b", 1))


class Rollback(unittest.TestCase):
    """--rollback holds the app at its previous commit until a new commit lands; a named run skips the backoff."""

    CTX = {"baseRefreshS": 10**6, "upstreams": UPSTREAMS, "backoff": {"baseS": 300, "maxS": 3600}}
    SPEC = {"repo": "o/a", "branch": "main", "watch": [], "hash": "x"}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_dir = self.tmp.name
        self.head = "b"
        self.deployed = []
        self.fail = False

        def build_deploy(ctx, app, spec_, sha):
            if self.fail:
                raise builder.BuildError("build failed")
            self.deployed.append(sha)
            return {"committed_at": 1, "built": 1, "reused": 0}

        self.patch = patched(
            branch_head=lambda ctx, repo, branch: self.head,
            app_build_deploy=build_deploy,
            time_now=lambda: 1000,
            log=lambda *a: None,
        )
        self.patch.__enter__()

    def tearDown(self):
        self.patch.__exit__(None, None, None)
        self.tmp.cleanup()

    def run_app(self, requested=False):
        state = builder.app_run(self.CTX, "a", self.SPEC, builder.state_load(self.state_dir, "a"), requested)
        builder.state_save(self.state_dir, "a", state)
        return state

    def test_a_rollback_holds_the_previous_commit_until_a_new_one(self):
        self.head = "a"
        self.run_app()
        self.head = "b"
        self.run_app()
        self.assertEqual((self.deployed, builder.state_load(self.state_dir, "a")["previous_sha"]), (["a", "b"], "a"))
        self.assertEqual(builder.app_rollback(self.state_dir, "a"), 0)
        self.assertEqual(builder.app_rollback(self.state_dir, "a"), 1, "a second rollback while held")
        state = self.run_app()
        self.assertEqual((self.deployed[-1], state["sha"], state["hold"]), ("a", "a", {"sha": "a", "head": "b"}))
        self.run_app()
        self.assertEqual(len(self.deployed), 3, "the held commit was deployed again while the head stood still")
        self.head = "c"
        state = self.run_app()
        self.assertEqual((self.deployed[-1], state["hold"], state["previous_sha"]), ("c", None, "a"))

    def test_nothing_to_roll_back_to(self):
        self.assertEqual(builder.app_rollback(self.state_dir, "a"), 1)
        self.run_app()
        self.assertEqual(builder.app_rollback(self.state_dir, "a"), 1)

    def test_a_named_run_tries_a_failing_commit_whatever_its_backoff(self):
        self.fail = True
        failure = self.run_app()["failure"]
        self.assertGreater(failure["retry_at"], 1000)
        self.fail = False
        self.run_app()
        self.assertEqual(self.deployed, [], "the timer's run went past the backoff")
        self.assertIsNone(self.run_app(requested=True)["failure"])
        self.assertEqual(self.deployed, ["b"])


class Deploy(unittest.TestCase):
    def deploy(self, manager, status=0):
        """The calls stack_deploy makes when the manager's swarm-deploy exits with `status`."""
        calls = []

        def run(args, timeout_s, **kw):
            calls.append((args, kw.get("input")))
            if args[0] == "ssh" and status != 0:
                raise builder.BuildError("ssh failed", status)
            return types.SimpleNamespace(stdout=f"{status}\n")

        saved = builder.process_run
        builder.process_run = run
        try:
            with tempfile.TemporaryDirectory() as inbox:
                ctx = {
                    "inbox": inbox,
                    "deployUnit": "swarm-deploy@",
                    "deployKeyFile": "/k",
                    "upstreams": UPSTREAMS,
                    "timeouts": {"deployS": 1, "sshConnectS": 1, "sshAliveIntervalS": 1, "sshAliveCountMax": 1},
                }
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
        self.assertEqual(
            calls,
            [
                (["systemctl", "start", "swarm-deploy@demo.service"], None),
                (["systemctl", "show", "-P", "ExecMainStatus", "swarm-deploy@demo.service"], None),
            ],
        )
        self.assertIn("image: x", kept)

    def test_a_guest_swarm_takes_it_over_its_forced_command(self):
        calls, kept = self.deploy({"address": "10.100.0.170", "knownHosts": "/kh"})
        self.assertEqual(kept, [])
        ((args, stdin),) = calls
        self.assertEqual((args[0], args[-2:]), ("ssh", ["root@10.100.0.170", "demo"]))
        self.assertIn("image: x", stdin)

    def test_a_manager_answering_unavailable_is_an_outage_and_any_other_status_a_failure(self):
        for manager in (None, {"address": "10.100.0.170", "knownHosts": "/kh"}):
            with self.subTest(manager=manager), self.assertRaises(builder.UpstreamUnavailable):
                self.deploy(manager, UNAVAILABLE)
        with self.assertRaises(builder.BuildError):
            self.deploy({"address": "10.100.0.170", "knownHosts": "/kh"}, 1)


class Upstreams(unittest.TestCase):
    """modules/upstream's contract in python: retried, then the probe decides between an outage and a failure."""

    def setUp(self):
        self.down = set()
        self.slept = []
        self.patch = patched(upstream_reachable=lambda ctx, name: name not in self.down, time_sleep=self.slept.append)
        self.patch.__enter__()
        self.ctx = {"registry": "r", "upstreams": UPSTREAMS}

    def tearDown(self):
        self.patch.__exit__(None, None, None)

    def call(self, failures):
        """upstream_call over a call failing its first `failures` times; how often it ran."""
        ran = []

        def call():
            ran.append(1)
            if len(ran) <= failures:
                raise builder.BuildError("down")
            return "ok"

        return builder.upstream_call(self.ctx, "github", call), len(ran)

    def test_a_blip_is_retried_with_a_doubling_backoff(self):
        self.assertEqual(self.call(2), ("ok", 3))
        self.assertEqual(self.slept, [5, 10])

    def test_after_the_last_attempt_the_probe_decides(self):
        with self.assertRaises(builder.BuildError) as own:
            self.call(3)
        self.assertNotIsInstance(own.exception, builder.UpstreamUnavailable)
        self.down.add("github")
        with self.assertRaises(builder.UpstreamUnavailable) as outage:
            self.call(3)
        self.assertEqual(outage.exception.name, "github")

    def test_an_image_names_its_registry_by_dockers_rule(self):
        for image, name in [
            ("alpine:3", "dockerhub"),
            ("alpine/socat:1", "dockerhub"),
            ("docker.io/library/redis", "dockerhub"),
            ("ghcr.io/o/i:1", "ghcr"),
            ("registry.lsck0.dev/a/web@sha256:0", None),
            ("localhost:5000/x", None),
        ]:
            with self.subTest(image=image):
                self.assertEqual(builder.image_upstream(self.ctx, image), name)

    def test_a_failed_build_is_an_outage_while_what_it_fetches_from_is_down(self):
        def build_fails(*args):
            raise builder.BuildError("build failed")

        with (
            tempfile.TemporaryDirectory() as repo,
            patched(
                image_build_push=build_fails,
                content_key=lambda *a: "k",
                registry_digest=lambda *a: None,
                log=lambda *a: None,
            ),
        ):
            write(repo, "Dockerfile", "FROM alpine:3\n")
            build = {"dockerfile": os.path.join(repo, "Dockerfile"), "args": {}}
            for down, raised in (
                (set(), builder.BuildError),
                ({"dockerhub"}, builder.UpstreamUnavailable),
                ({"github"}, builder.UpstreamUnavailable),
            ):
                self.down = down
                with self.subTest(down=down), self.assertRaises(raised):
                    builder.service_image(self.ctx, "a", "web", build, repo, {}, {})


class ContentKey(unittest.TestCase):
    """The key that decides between a build and a reuse, over a real git checkout."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        self.ctx = {"timeouts": {"gitS": 30}, "upstreams": UPSTREAMS}
        self.bases = {"debian:13": "sha256:" + "d" * 64}
        self.saved = builder.image_base_digest
        builder.image_base_digest = lambda ctx, image: self.bases[image]
        self.git("init", "-q")
        write(self.repo, "web/Dockerfile", "FROM scratch\nCOPY . /\n")
        write(self.repo, "web/index.html", "v1")
        write(self.repo, "README.md", "readme")
        self.commit()

    def tearDown(self):
        builder.image_base_digest = self.saved
        self.tmp.cleanup()

    def git(self, *args):
        import subprocess

        subprocess.run(["git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "c")

    def key(self, args=None, target=None, dockerfile="web/Dockerfile"):
        build = {
            "context": os.path.join(self.repo, "web"),
            "dockerfile": os.path.join(self.repo, dockerfile),
            "target": target,
            "args": {},
        }
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

    def test_a_new_base_image_digest_changes_it(self):
        write(self.repo, "web/Dockerfile", "FROM debian:13\nCOPY . /\n")
        self.commit()
        before = self.key()
        self.assertEqual(self.key(), before)
        self.bases["debian:13"] = "sha256:" + "e" * 64
        self.assertNotEqual(self.key(), before)


class Bases(unittest.TestCase):
    """dockerfile_bases: the images a dockerfile's stages start from, table by table."""

    CASES = [
        ("FROM scratch\n", {}, []),
        ("FROM debian:13 AS build\nFROM build\nFROM --platform=linux/amd64 alpine:3\n", {}, ["debian:13", "alpine:3"]),
        ("ARG BASE=debian:13\nFROM ${BASE}\n", {}, ["debian:13"]),
        ("ARG BASE=debian:13\nFROM $BASE\n", {"BASE": "alpine:3"}, ["alpine:3"]),
        ("from node:24 as deps\nfrom deps as run\n", {}, ["node:24"]),
        ("FROM redis@sha256:" + "f" * 64 + "\n", {}, ["redis@sha256:" + "f" * 64]),
    ]

    def bases(self, text, args):
        with tempfile.TemporaryDirectory() as tmp:
            write(tmp, "Dockerfile", text)
            return builder.dockerfile_bases(os.path.join(tmp, "Dockerfile"), args)

    def test_cases(self):
        for text, args, expected in self.CASES:
            with self.subTest(text=text):
                self.assertEqual(self.bases(text, args), expected)

    def test_an_argument_without_a_value_is_an_operating_error(self):
        for text in ("FROM ${BASE}\n", "FROM debian:13\nARG LATE=x\nFROM ${LATE}\n"):
            with self.subTest(text=text), self.assertRaises(builder.BuildError):
                self.bases(text, {})

    def test_a_pinned_base_is_its_own_digest(self):
        self.assertEqual(builder.image_base_digest({}, "redis@sha256:" + "f" * 64), "sha256:" + "f" * 64)


class CacheMounts(unittest.TestCase):
    """Another app's build never leaves a cache mount this app's build reads."""

    def test_the_cache_mounts_go_before_the_first_build(self):
        steps = []
        fakes = {
            "repo_checkout": lambda ctx, repo, sha, into: "2026-10-18T00:00:00+00:00",
            "stack_load": lambda spec_, repo_dir: ({"services": {"web": {"build": "."}}}, repo_dir),
            "build_resolve": lambda svc, override, stack_dir, repo_dir: {"context": repo_dir},
            "env_inline": lambda svc, stack_dir, repo_dir: None,
            "process_run": lambda args, timeout_s, **kw: steps.append(" ".join(args[:3])),
            "service_image": lambda *a: steps.append("build") or ("r/a/web@sha256:" + "1" * 64, True),
            "registry_login": lambda ctx: None,
            "stack_deploy": lambda *a: None,
            "image_mark_live": lambda *a: None,
            "log": lambda *a: None,
            "dashboards_publish": lambda *a: None,
        }
        ctx = {"loggedIn": False, "buildParallelism": 1, "upstreams": UPSTREAMS, "timeouts": {"buildS": 1}}
        spec_ = {"repo": "o/a", "build": {}, "exclude": [], "dashboards": [], "manager": None}
        with patched(**fakes):
            builder.app_build_deploy(ctx, "a", spec_, "c" * 40)
        self.assertEqual(steps, ["docker builder prune", "build"])


class Static(unittest.TestCase):
    """A static app: its command's site on the platform's server, one service, built once per content."""

    STATIC = {
        "command": "make site",
        "output": "out",
        "toolchain": "/nix/store/t",
        "root": "/srv/site",
        "server": {"archive": "s.tar.gz", "ref": "server:1"},
        "build": {"archive": "b.tar.gz", "ref": "build:1"},
        "indexable": "https://math.example",
    }

    def deploy(self, registry_holds):
        """The stack deployed and the docker commands run for one look at a static app."""
        deployed, commands = [], []

        def run(args, timeout_s, **kw):
            commands.append(args)
            if args[:2] == ["docker", "run"]:
                repo = args[args.index("-w") - 1].split(":")[0]
                write(repo, "out/index.html", "<p>home</p>")
                write(repo, "out/part/a b.html", "<p>a</p>")
            if args[:2] == ["docker", "commit"]:
                self.site = sorted(os.listdir(commands[-2][2][: -len("/.")]))
            return types.SimpleNamespace(stdout='["r/a/web@sha256:' + "1" * 64 + '"]')

        def checkout(ctx, repo, sha, into):
            return "2026-10-18T00:00:00+00:00"

        fakes = {
            "repo_checkout": checkout,
            "git_object": lambda *a: "tree",
            "process_run": run,
            "registry_digest": lambda *a: "sha256:" + "2" * 64 if registry_holds else None,
            "registry_login": lambda ctx: None,
            "stack_deploy": lambda ctx, app, m, stack: deployed.append(stack),
            "image_mark_live": lambda *a: None,
            "log": lambda *a: None,
            "dashboards_publish": lambda *a: None,
        }
        with patched(**fakes):
            ctx = {
                "registry": "r",
                "loggedIn": False,
                "buildParallelism": 1,
                "upstreams": UPSTREAMS,
                "timeouts": {"buildS": 1, "pushS": 1},
            }
            spec_ = {
                "repo": "o/a",
                "stack": None,
                "build": {},
                "exclude": [],
                "dashboards": [],
                "manager": None,
                "static": self.STATIC,
            }
            facts = builder.app_build_deploy(ctx, "a", spec_, "c" * 40)
        return deployed[0], commands, facts

    def test_a_new_site_is_built_without_network_and_laid_on_the_server(self):
        stack, commands, facts = self.deploy(registry_holds=False)
        self.assertEqual(list(stack["services"]), ["web"])
        self.assertTrue(stack["services"]["web"]["read_only"])
        self.assertEqual((facts["built"], facts["reused"]), (1, 0))
        run = next(c for c in commands if c[:2] == ["docker", "run"])
        self.assertEqual(run[run.index("--network") + 1], "none")
        self.assertEqual(run[-3:], ["sh", "-c", "make site"])
        self.assertEqual(self.site, ["index.html", "part", "robots.txt", "sitemap.xml"])

    def test_the_same_content_reuses_the_registry_image(self):
        _, commands, facts = self.deploy(registry_holds=True)
        self.assertEqual((facts["built"], facts["reused"]), (0, 1))
        self.assertFalse([c for c in commands if c[:2] == ["docker", "run"]])

    def test_the_sitemap_names_every_page_at_the_origin(self):
        with tempfile.TemporaryDirectory() as site:
            write(site, "index.html", "")
            write(site, "part/a b.html", "")
            write(site, "notes.pdf", "")
            builder.site_index_write(site, "https://math.example", "2026-10-18T00:00:00+00:00")
            with open(os.path.join(site, "sitemap.xml"), encoding="utf-8") as f:
                sitemap = f.read()
            with open(os.path.join(site, "robots.txt"), encoding="utf-8") as f:
                robots = f.read()
        self.assertIn("<loc>https://math.example/</loc><lastmod>2026-10-18</lastmod>", sitemap)
        self.assertIn("<loc>https://math.example/part/a%20b.html</loc>", sitemap)
        self.assertNotIn("notes.pdf", sitemap)
        self.assertIn("Allow: /", robots)
        self.assertIn("Sitemap: https://math.example/sitemap.xml", robots)

    def test_a_sites_own_robots_and_sitemap_win(self):
        with tempfile.TemporaryDirectory() as site:
            write(site, "robots.txt", "own")
            write(site, "sitemap.xml", "own")
            builder.site_index_write(site, "https://math.example", "2026-10-18")
            for name in ("robots.txt", "sitemap.xml"):
                with open(os.path.join(site, name), encoding="utf-8") as f:
                    self.assertEqual(f.read(), "own")

    def test_a_link_the_build_left_is_never_written_through(self):
        with tempfile.TemporaryDirectory() as root:
            site = os.path.join(root, "site")
            outside = os.path.join(root, "outside")
            os.makedirs(site)
            write(site, "index.html", "")
            # dangling: exists() is false for it, the write would create its target
            os.symlink(os.path.join(outside, "robots"), os.path.join(site, "robots.txt"))
            os.symlink(os.path.join(outside, "sitemap"), os.path.join(site, "sitemap.xml"))
            builder.site_index_write(site, "https://math.example", "2026-10-18")
            self.assertFalse(os.path.exists(outside))


class Schedule(unittest.TestCase):
    """A scheduled app is the poll's until its first deploy and after a catalog change, else its timer's alone."""

    CASES = [
        # schedule, deployed sha, state's build hash, only, waits
        (None, "s", "h", None, False),
        ("00:00", None, None, None, False),
        ("00:00", "s", "h", None, True),
        ("00:00", "s", "old", None, False),
        ("00:00", "s", "h", "a", False),
    ]

    def test_cases(self):
        for schedule, sha, build_hash, only, waits in self.CASES:
            with self.subTest(schedule=schedule, sha=sha, build_hash=build_hash, only=only):
                spec_ = {"schedule": schedule, "hash": "h"}
                state = dict(builder.STATE_EMPTY, sha=sha, build_hash=build_hash)
                self.assertEqual(builder.app_waits_for_schedule(spec_, state, only), waits)


if __name__ == "__main__":
    unittest.main()
