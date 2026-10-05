"""Policy and rendering of scripts/swarm-render.py: what an app stack may and may not become.

Usage: swarm_render_test.py <path to swarm-render.py>
"""
import importlib.util
import sys
import unittest

import yaml

spec = importlib.util.spec_from_file_location("swarm_render", sys.argv.pop(1))
render_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render_module)

APP = "demo"
DIGEST = "sha256:" + "a" * 64
OWN = f"registry.lsck0.dev/{APP}/web@{DIGEST}"
PUBLIC = "docker.io/library/redis:8@sha256:" + "b" * 64
CATALOG = {
    "exclude": ["grafana"],
    "stateful": ["db"],
    "override": {},
    "images": [PUBLIC],
    "paths": {"/": {"service": "web", "targetPort": 8000, "port": 20100}},
    "internal": {},
    "metrics": {"web": {"service": "web", "targetPort": 9100, "port": 20101, "path": "/metrics"}},
}


def render(stack, catalog=None, env=None):
    out = render_module.render(APP, catalog or CATALOG, env or {}, yaml.safe_load(yaml.safe_dump(stack)))
    return yaml.safe_load(out)


def base(**web):
    svc = {"image": OWN}
    svc.update(web)
    return {"services": {"web": svc, "db": {"image": PUBLIC, "volumes": ["data:/data"]}}, "volumes": {"data": {}}}


class Refused(unittest.TestCase):
    def refuses(self, stack, catalog=None, env=None):
        with self.assertRaises(SystemExit) as e:
            render(stack, catalog, env)
        self.assertEqual(e.exception.code, 2)

    def test_privileged_keys(self):
        for key, value in [("privileged", True), ("cap_add", ["SYS_ADMIN"]), ("network_mode", "host"),
                           ("pid", "host"), ("devices", ["/dev/kvm"]), ("security_opt", ["seccomp=unconfined"])]:
            with self.subTest(key=key):
                self.refuses(base(**{key: value}))

    def test_host_paths(self):
        for vol in ["/:/host", "./src:/src", "/var/run/docker.sock:/var/run/docker.sock",
                    {"type": "bind", "source": "/etc", "target": "/etc"}]:
            with self.subTest(vol=vol):
                self.refuses(base(volumes=[vol]))

    def test_unpinned_or_foreign_images(self):
        for image in [f"registry.lsck0.dev/{APP}/web:latest", f"registry.lsck0.dev/other/web@{DIGEST}",
                      "docker.io/library/redis:8", "evil.example/web@" + DIGEST]:
            with self.subTest(image=image):
                self.refuses(base(image=image))

    def test_unbuilt_service(self):
        self.refuses(base(build="."))

    def test_external_network(self):
        stack = base(networks=["outside"])
        stack["networks"] = {"outside": {"external": True}}
        self.refuses(stack)

    def test_placeholder_left(self):
        self.refuses(base(environment={"PASSWORD": "CHANGE_ME"}))

    def test_cross_app_volume_and_network_names(self):
        stack = base()
        stack["volumes"]["data"] = {"name": "wat_postgres-data"}
        self.refuses(stack)
        stack = base()
        stack["networks"] = {"default": {"name": "wat_default"}}
        self.refuses(stack)

    def test_placement_on_homelab_labels(self):
        self.refuses(base(deploy={"placement": {"constraints": ["node.labels.homelab.state == true"]}}))

    def test_global_mode_and_too_many_replicas(self):
        self.refuses(base(deploy={"mode": "global"}))
        self.refuses(base(deploy={"replicas": 500}))

    def test_ulimits(self):
        self.refuses(base(ulimits={"nofile": 1048576}))

    def test_top_level_configs_and_secrets(self):
        for key in ("configs", "secrets"):
            with self.subTest(key=key):
                stack = base()
                stack[key] = {"x": {"file": "/var/lib/swarm-manager-nas/unlock-key"}}
                self.refuses(stack)

    def test_publishing_a_missing_service(self):
        catalog = dict(CATALOG, paths={"/": {"service": "nope", "targetPort": 1, "port": 20102}})
        self.refuses(base(), catalog)


class Rendered(unittest.TestCase):
    def test_homelab_ports_replace_the_apps_own(self):
        out = render(base(ports=["80:8000"]))
        ports = {(p["target"], p["published"]) for p in out["services"]["web"]["ports"]}
        self.assertEqual(ports, {(8000, 20100), (9100, 20101)})
        self.assertEqual(out["services"]["db"]["ports"], [])

    def test_networks_are_encrypted_overlays(self):
        out = render(base())
        default = out["networks"]["default"]
        self.assertEqual(default["driver"], "overlay")
        self.assertEqual(default["driver_opts"]["encrypted"], "true")
        self.assertFalse(default["attachable"])

    def test_stateful_services_stay_on_the_state_node(self):
        db = render(base())["services"]["db"]["deploy"]
        self.assertIn(render_module.STATE_CONSTRAINT, db["placement"]["constraints"])
        self.assertEqual(db["update_config"]["order"], "stop-first")
        self.assertEqual(db["replicas"], 1)

    def test_stateless_services_roll_start_first_and_back(self):
        web = render(base())["services"]["web"]["deploy"]
        self.assertEqual(web["update_config"]["order"], "start-first")
        self.assertEqual(web["update_config"]["failure_action"], "rollback")
        self.assertEqual(web["restart_policy"]["condition"], "any")

    def test_restart_attempts_are_unbounded(self):
        out = render(base(deploy={"restart_policy": {"condition": "on-failure", "max_attempts": 5}}))
        self.assertNotIn("max_attempts", out["services"]["web"]["deploy"]["restart_policy"])

    def test_catalog_env_wins_and_resolves_placeholders(self):
        out = render(base(environment={"PASSWORD": "CHANGE_ME", "KEEP": "x"}), env={"PASSWORD": "s3cret"})
        self.assertEqual(out["services"]["web"]["environment"], {"PASSWORD": "s3cret", "KEEP": "x"})

    def test_excluded_services_and_their_dependencies_go(self):
        stack = base(depends_on=["grafana", "db"])
        stack["services"]["grafana"] = {"image": PUBLIC}
        out = render(stack)
        self.assertNotIn("grafana", out["services"])
        self.assertEqual(out["services"]["web"]["depends_on"], ["db"])

    def test_logging_and_env_files_are_dropped(self):
        out = render(base(logging={"driver": "none"}, env_file=["./prod.env"]))
        self.assertNotIn("logging", out["services"]["web"])
        self.assertNotIn("env_file", out["services"]["web"])

    def test_default_resource_limits(self):
        limits = render(base())["services"]["web"]["deploy"]["resources"]["limits"]
        self.assertEqual(limits, {"memory": render_module.MEMORY_LIMIT_DEFAULT, "pids": render_module.PIDS_LIMIT_DEFAULT})
        own = render(base(deploy={"resources": {"limits": {"memory": "4G"}}}))["services"]["web"]["deploy"]
        self.assertEqual(own["resources"]["limits"]["memory"], "4G")

    def test_dollars_stay_literal_through_stack_deploy(self):
        out = render(base(environment={"HASH": "$2y$10$abc"}), env={"SECRET": "a$b"})
        self.assertEqual(out["services"]["web"]["environment"], {"HASH": "$$2y$$10$$abc", "SECRET": "a$$b"})

    def test_override_merges_last(self):
        catalog = dict(CATALOG, override={"services": {"web": {"command": ["serve"]}}})
        self.assertEqual(render(base(), catalog)["services"]["web"]["command"], ["serve"])


if __name__ == "__main__":
    unittest.main()
