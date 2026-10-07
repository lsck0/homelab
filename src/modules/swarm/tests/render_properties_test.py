"""Laws of the apps platform's two parsers, over generated input (hypothesis, derandomized: one fixed run).

Usage: render_properties_test.py <path to swarm-render.py> <path to app-builder.py>

swarm-render: any stack either is refused (exit 2) or renders into one that keeps every policy law: only allowed
keys, every image digest-pinned (own build or catalog image), only named volumes of stateful services, encrypted
non-attachable overlays, ports exactly the catalog's, stateful services pinned, single and stop-first both ways,
the catalog's limits, restart on any exit, rollback on failure, and every string escaped so that unescaping gives
the input's literal value back. Rendering a rendered stack again changes nothing.
app-builder: a path resolved in a checkout full of symlinks lands inside it or raises; an env map written as a
dotenv file and read back is the same map. swarm-render's env file the same.
"""
import importlib.util
import os
import sys
import tempfile
import unittest

import yaml
from hypothesis import HealthCheck, example, given, settings
from hypothesis import strategies as st

sys.dont_write_bytecode = True


def module_load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


render_module = module_load("swarm_render", sys.argv.pop(1))
builder = module_load("app_builder", sys.argv.pop(1))

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

APP = "demo"
REGISTRY = "registry.lsck0.dev"
DIGEST = "@sha256:" + "c" * 64
PUBLIC = "docker.io/library/redis:8" + DIGEST
TASK_DEFAULTS = {"memoryMiB": 512, "cpus": 1.0, "pids": 512, "cpuMillis": 100}
GENERIC = {"memory": "HOMELAB_MEMORY_MIB", "cpu": "HOMELAB_CPU_MILLIS"}
REPLICAS_MAX = 6
SERVICES = ("web", "db", "worker")
VOLUMES = ("data", "cache")
PROPERTY_SETTINGS = settings(derandomize=True, database=None, max_examples=400, deadline=None,
                             suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much])


def catalog_of():
    return {"registry": REGISTRY, "replicasMax": REPLICAS_MAX, "replicasPerNodeMax": 2, "servicesMax": 32,
            "taskDefaults": TASK_DEFAULTS, "genericResources": GENERIC, "tenantHeader": "X-Scope-OrgID",
            "stackBytesMax": 1024 * 1024, "apps": {APP: {
                "exclude": ["grafana"], "stateful": ["db"], "volumes": {"data": {"backup": True}},
                "override": {}, "images": [PUBLIC],
                "published": [{"service": "web", "targetPort": 8000, "port": 20100},
                              {"service": "worker", "targetPort": 9100, "port": 20101}],
                "resources": {"web": {"memoryMiB": 1024, "cpus": 2.0, "pids": 256, "cpuMillis": 250}},
                "reservation": {"memoryMiB": 1024 * 64, "cpuMillis": 1000 * 64}, "tenant": None}}}


# -----------------------------------------------------------------------------
# STRATEGIES
# -----------------------------------------------------------------------------

literal = st.text(alphabet=st.characters(blacklist_categories=("Cs",), blacklist_characters="\x00"), max_size=12)
own_image = f"{REGISTRY}/{APP}/web{DIGEST}"
images_valid = st.sampled_from([own_image, PUBLIC])
images_any = st.sampled_from([own_image, PUBLIC, f"{REGISTRY}/{APP}/web:latest", f"{REGISTRY}/other/web{DIGEST}", "alpine"])
mounts_valid = st.sampled_from(["data:/data", "data:/data:ro", {"type": "tmpfs", "target": "/t"}])
mounts_any = st.sampled_from(["data:/data", "cache:/cache", "/:/host", "data:/data:ro", {"type": "tmpfs", "target": "/t"},
                              {"type": "bind", "source": "/etc", "target": "/e"}, "/anon", "~/x:/x"])
deploys_valid = st.fixed_dictionaries({}, optional={
    "replicas": st.integers(min_value=0, max_value=REPLICAS_MAX),
    "placement": st.just({"constraints": ["node.role == worker"]}),
    "resources": st.just({"limits": {"memory": "100G", "pids": 0}}),
    "update_config": st.sampled_from([{"order": "start-first"}, {"failure_action": "continue"}, {"parallelism": 2}]),
    "rollback_config": st.sampled_from([{"order": "start-first"}, {"order": "stop-first"}]),
    "restart_policy": st.sampled_from([{"condition": "on-failure", "max_attempts": 3}, {"condition": "none"}]),
})
deploys_any = st.fixed_dictionaries({}, optional={
    "replicas": st.integers(min_value=-1, max_value=REPLICAS_MAX + 2),
    "mode": st.sampled_from(["replicated", "global"]),
    "placement": st.sampled_from([{"constraints": ["node.labels.homelab.state == true"]}, {"nodes": ["x"]}]),
    "update_config": st.just({"bogus": 1}),
})


def services_of(images, mounts, deploys):
    return st.fixed_dictionaries({"image": images}, optional={
        "environment": st.dictionaries(st.sampled_from(["A", "B", "C"]), literal, max_size=3),
        "command": st.lists(literal, max_size=3),
        "volumes": st.lists(mounts, max_size=2),
        "deploy": deploys,
        "ports": st.just(["80:8000"]),
        "logging": st.just({"driver": "none"}),
        "healthcheck": st.just({"test": ["CMD", "true"]}),
    })


forbidden = st.sampled_from([("privileged", True), ("oom_score_adj", -1000), ("network_mode", "host"), ("build", ".")])
networks_valid = st.sampled_from([{}, {"default": {}}, {"default": {"attachable": True}}, {"backend": {"internal": True}}])
networks_any = st.sampled_from([{"x": {"external": True}}, {"default": {"ipam": {"config": [{"subnet": "10.100.0.0/24"}]}}},
                                {"default": {"name": "other_default"}}])


@st.composite
def stacks(draw):
    """A stack in compose source form: mostly one the policy accepts, sometimes with one broken part."""
    broken = draw(st.integers(min_value=0, max_value=3)) == 0
    stack = {"services": {}, "networks": draw(networks_any if broken and draw(st.booleans()) else networks_valid),
             "volumes": {v: {} for v in draw(st.lists(st.sampled_from(VOLUMES), unique=True))} | {"data": {}}}
    for name in SERVICES:
        stateful = name == "db"
        if broken:
            svc = draw(services_of(images_any, mounts_any, deploys_any))
            if draw(st.booleans()):
                key, value = draw(forbidden)
                svc[key] = value
        else:
            svc = draw(services_of(images_valid, mounts_valid if stateful else st.just({"type": "tmpfs", "target": "/t"}),
                                   deploys_valid))
        stack["services"][name] = svc
    if draw(st.booleans()):
        stack["services"]["grafana"] = {"image": "grafana", "privileged": True}
    return stack


def compose_escape_tree(node):
    if isinstance(node, dict):
        return {k: compose_escape_tree(v) for k, v in node.items()}
    if isinstance(node, list):
        return [compose_escape_tree(v) for v in node]
    if isinstance(node, str):
        return node.replace("$", "$$")
    return node


def render_or_refuse(stack, env=None):
    try:
        return yaml.safe_load(render_module.render(APP, catalog_of(), env or {}, stack))
    except SystemExit as e:
        assert e.code == 2, e.code
        return None


# -----------------------------------------------------------------------------
# PROPERTIES
# -----------------------------------------------------------------------------

class RenderLaws(unittest.TestCase):
    def assert_policy(self, out):
        spec = catalog_of()["apps"][APP]
        published = {}
        for p in spec["published"]:
            published.setdefault(p["service"], set()).add((p["targetPort"], p["port"]))
        self.assertNotIn("grafana", out["services"])
        for name, svc in out["services"].items():
            self.assertLessEqual(set(svc), render_module.SERVICE_KEYS - render_module.SERVICE_KEYS_DROPPED | {"ports"})
            image = svc["image"]
            self.assertTrue(image in spec["images"] or (image.startswith(f"{REGISTRY}/{APP}/") and "@sha256:" in image))
            self.assertEqual({(p["target"], p["published"]) for p in svc["ports"]}, published.get(name, set()))
            deploy = svc["deploy"]
            self.assertLessEqual(set(deploy), render_module.DEPLOY_KEYS)
            self.assertEqual(deploy["restart_policy"]["condition"], "any")
            self.assertEqual(deploy["update_config"]["failure_action"], "rollback")
            limits = spec["resources"].get(name, TASK_DEFAULTS)
            self.assertEqual(deploy["resources"], render_module.resources_render(limits, GENERIC))
            for vol in svc.get("volumes", []):
                if isinstance(vol, str):
                    self.assertIn(name, spec["stateful"])
                    self.assertIn(vol.split(":")[0], spec["volumes"])
                else:
                    self.assertEqual(vol["type"], "tmpfs")
            if name in spec["stateful"]:
                self.assertIn(render_module.STATE_CONSTRAINT, deploy["placement"]["constraints"])
                self.assertEqual(deploy["replicas"], 1)
                self.assertEqual(deploy["update_config"]["order"], "stop-first")
                self.assertEqual(deploy.get("rollback_config", {}).get("order"), "stop-first")
            else:
                for constraint in deploy.get("placement", {}).get("constraints", []):
                    self.assertNotIn("homelab.", constraint)
        for net in out["networks"].values():
            self.assertEqual(net["driver"], "overlay")
            self.assertEqual(net["driver_opts"], {"encrypted": "true"})
            self.assertFalse(net["attachable"])
            self.assertNotIn("ipam", net)
            self.assertNotIn("external", net)
        for vol in out.get("volumes", {}).values():
            self.assertLessEqual(set(vol), render_module.VOLUME_KEYS)

    @PROPERTY_SETTINGS
    @given(stacks())
    @example({"services": {"web": {"image": f"{REGISTRY}/{APP}/web{DIGEST}", "deploy": {"replicas": 2}},
                           "db": {"image": PUBLIC, "volumes": ["data:/data"], "deploy": {"replicas": 2}},
                           "worker": {"image": PUBLIC}}, "networks": {}, "volumes": {"data": {}}})
    def test_refused_or_lawful_and_idempotent(self, stack):
        out = render_or_refuse(stack)
        if out is None:
            return
        self.assert_policy(out)
        again = render_or_refuse(out)
        self.assertEqual(again, out)

    @PROPERTY_SETTINGS
    @given(st.dictionaries(st.sampled_from(["A", "B", "C"]), literal, max_size=3), literal)
    def test_values_stay_literal(self, environment, secret):
        stack = {"services": {"web": {"image": f"{REGISTRY}/{APP}/web{DIGEST}",
                                      "environment": compose_escape_tree(environment)},
                              "db": {"image": PUBLIC, "volumes": ["data:/data"]},
                              "worker": {"image": PUBLIC}},
                 "volumes": {"data": {}}}
        out = render_or_refuse(stack, env={"web": {"SECRET": secret}})
        if out is None:
            self.assertTrue(any("CHANGE_ME" in v for v in list(environment.values()) + [secret]))
            return
        rendered = {k: v.replace("$$", "$") for k, v in out["services"]["web"]["environment"].items()}
        self.assertEqual(rendered, dict(environment, SECRET=secret))


class BuilderLaws(unittest.TestCase):
    @PROPERTY_SETTINGS
    @given(st.lists(st.tuples(st.sampled_from(["a", "b", "a/c", "b/d"]),
                              st.sampled_from([".", "..", "../..", "/", "/etc", "a", "a/c", "b/d", "missing", "a/../.."])),
                    max_size=4),
           st.sampled_from([".", "a", "b", "a/c", "b/d/e", "../x", "a/../../x", "/etc/passwd", "a/c/../../..", "b/d/../.."]))
    def test_resolved_paths_stay_inside(self, links, path):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "repo")
            os.makedirs(repo)
            for link, target in links:
                full = os.path.join(repo, link)
                # a link under an earlier link may point anywhere, the root included: such a tree is no fixture
                try:
                    os.makedirs(os.path.dirname(full), exist_ok=True)
                    if not os.path.lexists(full):
                        os.symlink(target, full)
                except OSError:
                    continue
            real = os.path.realpath(repo)
            try:
                resolved = builder.path_resolve_inside(repo, path)
            except builder.BuildError:
                return
            self.assertTrue(resolved == real or resolved.startswith(real + os.sep), (links, path, resolved))

    @PROPERTY_SETTINGS
    @given(st.dictionaries(st.from_regex(r"[A-Z_][A-Z0-9_]{0,8}", fullmatch=True),
                           st.text(alphabet=st.characters(blacklist_categories=("Cs", "Cc"), blacklist_characters="'"), max_size=12),
                           max_size=5))
    def test_dotenv_round_trip(self, env):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "x.env")
            with open(path, "w", encoding="utf-8") as f:
                f.write("".join(f"{k}='{v}'\n" for k, v in env.items()))
            self.assertEqual(builder.env_file_read(path), env)

    @PROPERTY_SETTINGS
    @given(st.dictionaries(st.from_regex(r"[a-z][a-z0-9._-]{0,6}", fullmatch=True),
                           st.dictionaries(st.from_regex(r"[A-Z_][A-Z0-9_]{0,8}", fullmatch=True),
                                           st.text(alphabet=st.characters(blacklist_categories=("Cs",), blacklist_characters="\n\r\x0b\x0c\x1c\x1d\x1e\x85\u2028\u2029"), max_size=12),
                                           min_size=1, max_size=3), max_size=3))
    def test_render_env_file_round_trip(self, env):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "app.env")
            with open(path, "w", encoding="utf-8") as f:
                f.write("".join(f"{s}.{k}={v}\n" for s, kv in env.items() for k, v in kv.items()))
            self.assertEqual(render_module.env_file_parse(path), env)


if __name__ == "__main__":
    unittest.main()
