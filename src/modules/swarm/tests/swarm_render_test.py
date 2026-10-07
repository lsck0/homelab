"""Policy and rendering of lib/swarm-render.py: what an app stack may and may not become, table by table.

Usage: swarm_render_test.py <path to swarm-render.py>
"""
import importlib.util
import sys
import unittest

import yaml

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("swarm_render", sys.argv.pop(1))
render_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render_module)

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

APP = "demo"
REGISTRY = "registry.lsck0.dev"
DIGEST = "sha256:" + "a" * 64
OWN = f"{REGISTRY}/{APP}/web@{DIGEST}"
PUBLIC = "docker.io/library/redis:8@sha256:" + "b" * 64
TASK_DEFAULTS = {"memoryMiB": 512, "cpus": 1.0, "pids": 512, "cpuMillis": 100}
GENERIC = {"memory": "HOMELAB_MEMORY_MIB", "cpu": "HOMELAB_CPU_MILLIS"}
SPEC = {
    "exclude": ["grafana"],
    "stateful": ["db"],
    "volumes": {"data": {"backup": True}},
    "override": {},
    "images": [PUBLIC],
    "published": [{"service": "web", "targetPort": 8000, "port": 20100, "protocol": "tcp"},
                  {"service": "web", "targetPort": 9100, "port": 20101, "protocol": "tcp"}],
    "resources": {},
    "reservation": {"memoryMiB": 8192, "cpuMillis": 4000},
}
REPLICAS_MAX = 6
REPLICAS_LABEL = "homelab.replicas"


# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------

def catalog_of(**changes):
    app = dict(SPEC, **changes)
    return {"registry": REGISTRY, "replicasMax": REPLICAS_MAX, "replicasPerNodeMax": 2, "servicesMax": 32,
            "taskDefaults": TASK_DEFAULTS, "genericResources": GENERIC, "replicasLabel": REPLICAS_LABEL,
            "stackBytesMax": 1024 * 1024, "apps": {APP: app}}


def render(stack, catalog=None, env=None):
    out = render_module.render(APP, catalog or catalog_of(), env or {}, stack)
    return yaml.safe_load(out)


def base(**web):
    svc = {"image": OWN}
    svc.update(web)
    return {"services": {"web": svc, "db": {"image": PUBLIC, "volumes": ["data:/data"]}}, "volumes": {"data": {}}}


def unescape(value):
    return value.replace("$$", "$")


# -----------------------------------------------------------------------------
# TESTS
# -----------------------------------------------------------------------------

class Refused(unittest.TestCase):
    def refuses(self, stack, catalog=None, env=None):
        with self.assertRaises(SystemExit) as e:
            render(stack, catalog, env)
        self.assertEqual(e.exception.code, 2)

    def test_positive_control(self):
        # every refusal below changes one thing of this stack, which renders
        render(base())

    def test_keys_outside_the_allow_list(self):
        for key, value in [("privileged", True), ("cap_add", ["SYS_ADMIN"]), ("network_mode", "host"),
                           ("pid", "host"), ("devices", ["/dev/kvm"]), ("security_opt", ["seccomp=unconfined"]),
                           ("ulimits", {"nofile": 1048576}), ("oom_score_adj", -1000), ("sysctls", {"a": 1}),
                           ("dns", ["10.100.0.1"]), ("configs", ["x"]), ("secrets", ["x"])]:
            with self.subTest(key=key):
                self.refuses(base(**{key: value}))

    def test_deploy_keys_outside_the_allow_list(self):
        for deploy in [{"mode": "global"}, {"replicas": REPLICAS_MAX + 1}, {"replicas": "3"},
                       {"placement": {"constraints": ["node.labels.homelab.state == true"]}},
                       {"placement": {"nodes": ["vm-150"]}}, {"isolation": "default"},
                       {"update_config": {"rollback_on_any": True}}]:
            with self.subTest(deploy=deploy):
                self.refuses(base(deploy=deploy))

    def test_host_paths_and_anonymous_volumes(self):
        for vol in ["/:/host", "./src:/src", "/var/run/docker.sock:/var/run/docker.sock", "/data",
                    {"type": "bind", "source": "/etc", "target": "/etc"}, "data:/data:z"]:
            with self.subTest(vol=vol):
                stack = base()
                stack["services"]["db"]["volumes"] = [vol]
                self.refuses(stack)

    def test_volumes_belong_to_declared_stateful_services(self):
        stack = base(volumes=["data:/data"])
        self.refuses(stack)
        self.refuses(base(), catalog_of(volumes={}))
        stack = base()
        stack["services"]["db"]["volumes"] = ["other:/data"]
        self.refuses(stack)

    def test_unpinned_or_foreign_images(self):
        for image in [f"{REGISTRY}/{APP}/web:latest", f"{REGISTRY}/other/web@{DIGEST}",
                      "docker.io/library/redis:8", "evil.example/web@" + DIGEST]:
            with self.subTest(image=image):
                self.refuses(base(image=image))

    def test_unbuilt_service(self):
        self.refuses(base(build="."))

    def test_networks(self):
        for net in [{"external": True}, {"name": "wat_default"}, {"ipam": {"config": [{"subnet": "10.100.0.0/24"}]}},
                    {"driver_opts": {"com.docker.network.driver.mtu": "9000"}}, {"enable_ipv6": True}]:
            with self.subTest(net=net):
                stack = base()
                stack["networks"] = {"default": net}
                self.refuses(stack)

    def test_cross_app_volume_names_and_drivers(self):
        for vol in [{"name": "wat_postgres-data"}, {"driver": "local"}, {"external": True}]:
            with self.subTest(vol=vol):
                stack = base()
                stack["volumes"]["data"] = vol
                self.refuses(stack)

    def test_placeholder_left(self):
        self.refuses(base(environment={"PASSWORD": "CHANGE_ME"}))

    def test_interpolation(self):
        for value in ["${HOME}", "$HOME", "a$", "${VAR:?required}"]:
            with self.subTest(value=value):
                self.refuses(base(command=["echo", value]))
                self.refuses(base(environment={"A": value}))

    def test_top_level_keys(self):
        for key in ("configs", "secrets", "name", "include"):
            with self.subTest(key=key):
                stack = base()
                stack[key] = {"x": {"file": "/var/lib/swarm-manager-nas/unlock-key"}}
                self.refuses(stack)

    def test_catalog_names_services_the_stack_lacks(self):
        self.refuses(base(), catalog_of(published=[{"service": "nope", "targetPort": 1, "port": 20102, "protocol": "tcp"}]))
        self.refuses(base(), catalog_of(stateful=["db", "nope"]))
        self.refuses(base(), env={"nope": {"A": "1"}})
        self.refuses(base(), catalog_of(resources={"nope": TASK_DEFAULTS}))


class Rendered(unittest.TestCase):
    def test_homelab_ports_replace_the_apps_own(self):
        out = render(base(ports=["80:8000"]))
        ports = {(p["target"], p["published"], p["protocol"]) for p in out["services"]["web"]["ports"]}
        self.assertEqual(ports, {(8000, 20100, "tcp"), (9100, 20101, "tcp")})
        self.assertEqual(out["services"]["db"]["ports"], [])

    def test_a_udp_route_is_published_as_udp(self):
        catalog = catalog_of(published=[{"service": "web", "targetPort": 27015, "port": 20120, "protocol": "udp"},
                                        {"service": "web", "targetPort": 27015, "port": 20121, "protocol": "tcp"}])
        ports = {(p["target"], p["published"], p["protocol"]) for p in render(base(), catalog)["services"]["web"]["ports"]}
        self.assertEqual(ports, {(27015, 20120, "udp"), (27015, 20121, "tcp")})

    def test_every_service_carries_its_replicas_asleep_too(self):
        # an idle app's wake scales each service back to this label (modules/swarm swarm-idle-wake)
        stack = base(deploy={"replicas": 2, "labels": ["keep=1", f"{REPLICAS_LABEL}=9"]})
        stack["services"]["db"]["deploy"] = {"replicas": 3}
        out = render(stack)
        self.assertEqual(out["services"]["web"]["deploy"]["labels"], {"keep": "1", REPLICAS_LABEL: "2"})
        self.assertEqual(out["services"]["db"]["deploy"]["labels"], {REPLICAS_LABEL: "1"})
        asleep = yaml.safe_load(render_module.replicas_stop(render_module.render(APP, catalog_of(), {}, stack)))
        self.assertEqual({n: s["deploy"]["replicas"] for n, s in asleep["services"].items()}, {"web": 0, "db": 0})
        self.assertEqual(asleep["services"]["web"]["deploy"]["labels"][REPLICAS_LABEL], "2")

    def test_networks_are_encrypted_overlays(self):
        out = render(base())
        default = out["networks"]["default"]
        self.assertEqual(default["driver"], "overlay")
        self.assertEqual(default["driver_opts"], {"encrypted": "true"})
        self.assertFalse(default["attachable"])

    def test_stateful_services_stay_on_the_state_node_and_never_overlap(self):
        stack = base()
        stack["services"]["db"]["deploy"] = {"replicas": 3, "update_config": {"order": "start-first"},
                                             "rollback_config": {"order": "start-first"}}
        db = render(stack)["services"]["db"]["deploy"]
        self.assertIn(render_module.STATE_CONSTRAINT, db["placement"]["constraints"])
        self.assertEqual(db["update_config"]["order"], "stop-first")
        self.assertEqual(db["rollback_config"]["order"], "stop-first")
        self.assertEqual(db["replicas"], 1)

    def test_stateless_services_roll_start_first_and_back(self):
        web = render(base(deploy={"update_config": {"failure_action": "continue"}}))["services"]["web"]["deploy"]
        self.assertEqual(web["update_config"]["order"], "start-first")
        self.assertEqual(web["update_config"]["failure_action"], "rollback")
        self.assertEqual(web["restart_policy"]["condition"], "any")
        self.assertNotIn("constraints", web["placement"])

    def test_anchored_deploy_blocks_are_independent(self):
        # one yaml alias under a stateless and a stateful service, in both orders
        for first, second in (("aweb", "zdb"), ("web", "db")):
            with self.subTest(order=(first, second)):
                text = (f"x-dep: &dep {{replicas: 3}}\nservices:\n  {first}: {{image: '{OWN}', deploy: *dep}}\n"
                        f"  {second}: {{image: '{PUBLIC}', deploy: *dep, volumes: ['data:/data']}}\nvolumes: {{data: {{}}}}\n")
                catalog = catalog_of(stateful=[second], published=[{"service": first, "targetPort": 8000, "port": 20100,
                                                                   "protocol": "tcp"}])
                out = render(yaml.safe_load(text), catalog)
                self.assertEqual(out["services"][first]["deploy"]["replicas"], 3)
                self.assertNotIn("constraints", out["services"][first]["deploy"]["placement"])
                self.assertEqual(out["services"][second]["deploy"]["replicas"], 1)

    def test_restart_attempts_are_unbounded(self):
        out = render(base(deploy={"restart_policy": {"condition": "on-failure", "max_attempts": 5}}))
        self.assertNotIn("max_attempts", out["services"]["web"]["deploy"]["restart_policy"])

    def test_catalog_env_reaches_its_service_only(self):
        out = render(base(environment={"PASSWORD": "CHANGE_ME", "KEEP": "x"}),
                     env={"web": {"PASSWORD": "s3cret"}, "db": {"DB_PASSWORD": "d"}})
        self.assertEqual(out["services"]["web"]["environment"], {"PASSWORD": "s3cret", "KEEP": "x"})
        self.assertEqual(out["services"]["db"]["environment"], {"DB_PASSWORD": "d"})

    def test_excluded_services_and_their_dependencies_go(self):
        stack = base(depends_on=["grafana", "db"])
        stack["services"]["grafana"] = {"image": PUBLIC, "privileged": True}
        out = render(stack)
        self.assertNotIn("grafana", out["services"])
        self.assertEqual(out["services"]["web"]["depends_on"], ["db"])

    def test_logging_env_files_and_unused_volumes_are_dropped(self):
        stack = base(logging={"driver": "none"}, env_file=["./prod.env"], container_name="x", restart="always")
        stack["volumes"]["unused"] = {}
        out = render(stack)
        for key in ("logging", "env_file", "container_name", "restart"):
            self.assertNotIn(key, out["services"]["web"])
        self.assertEqual(set(out["volumes"]), {"data"})

    def test_limits_are_the_catalogs(self):
        limits = render(base(deploy={"resources": {"limits": {"memory": "100G", "pids": 0}}}))
        self.assertEqual(limits["services"]["web"]["deploy"]["resources"]["limits"],
                         {"memory": "512M", "cpus": "1.0", "pids": 512})
        own = render(base(), catalog_of(resources={"web": {"memoryMiB": 2048, "cpus": 2.0, "pids": 1024, "cpuMillis": 500}}))
        self.assertEqual(own["services"]["web"]["deploy"]["resources"]["limits"],
                         {"memory": "2048M", "cpus": "2.0", "pids": 1024})

    def test_dollars_stay_literal_through_stack_deploy(self):
        out = render(base(environment={"HASH": "$$2y$$10$$abc"}, command=["sh", "-c", "echo $$HOME"]),
                     env={"web": {"SECRET": "a$b"}})
        web = out["services"]["web"]
        self.assertEqual(web["environment"], {"HASH": "$$2y$$10$$abc", "SECRET": "a$$b"})
        self.assertEqual(web["command"], ["sh", "-c", "echo $$HOME"])
        self.assertEqual(unescape(web["environment"]["SECRET"]), "a$b")

    def test_swarm_templates_pass(self):
        out = render(base(), env={"web": {"HOST": "{{.Node.Hostname}}"}})
        self.assertEqual(out["services"]["web"]["environment"]["HOST"], "{{.Node.Hostname}}")

    def test_override_merges_last(self):
        catalog = catalog_of(override={"services": {"web": {"command": ["serve"]}}})
        self.assertEqual(render(base(), catalog)["services"]["web"]["command"], ["serve"])

    def test_extension_fields_and_version_go(self):
        stack = base()
        stack["version"] = "3.9"
        stack["x-common"] = {"a": 1}
        out = render(stack)
        self.assertNotIn("version", out)
        self.assertNotIn("x-common", out)

    def test_tmpfs_mounts_pass(self):
        out = render(base(volumes=[{"type": "tmpfs", "target": "/tmp"}]))
        self.assertEqual(out["services"]["web"]["volumes"], [{"type": "tmpfs", "target": "/tmp"}])

    def test_input_is_not_mutated(self):
        stack = base(deploy={"replicas": 2})
        before = yaml.safe_dump(stack)
        render(stack)
        self.assertEqual(yaml.safe_dump(stack), before)


if __name__ == "__main__":
    unittest.main()
