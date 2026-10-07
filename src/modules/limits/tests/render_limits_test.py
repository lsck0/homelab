"""The apps' share of the swarm as modules/swarm/lib/swarm-render.py renders and admits it, table by table: reservations, the
workers' generic resources, the app's reservation, placement over the workers, capabilities, the telemetry tenant.

Usage: render_limits_test.py <path to swarm-render.py>
"""
import importlib.util
import sys
import unittest
from contextlib import redirect_stderr
from io import StringIO

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
OWN = f"{REGISTRY}/{APP}/web@sha256:" + "a" * 64
TASK_DEFAULTS = {"memoryMiB": 512, "cpus": 1.0, "pids": 512, "cpuMillis": 100}
GENERIC = {"memory": "HOMELAB_MEMORY_MIB", "cpu": "HOMELAB_CPU_MILLIS"}
HEADER = "X-Scope-OrgID"
OTLP = "OTEL_EXPORTER_OTLP_HEADERS"
PER_NODE = 2
SERVICES_MAX = 4


# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------

def catalog_of(memory=1024, cpu=500, tenant=None, resources=None, stateful=(), exclude=(), override=None):
    app = {"exclude": list(exclude), "stateful": list(stateful), "volumes": {"data": {"backup": False}},
           "override": override or {}, "images": [],
           "published": [{"service": "web", "targetPort": 8000, "port": 20100}],
           "resources": resources or {}, "reservation": {"memoryMiB": memory, "cpuMillis": cpu}, "tenant": tenant}
    return {"registry": REGISTRY, "replicasMax": 5, "replicasPerNodeMax": PER_NODE, "servicesMax": SERVICES_MAX,
            "taskDefaults": TASK_DEFAULTS, "genericResources": GENERIC, "tenantHeader": HEADER,
            "stackBytesMax": 1024 * 1024, "apps": {APP: app}}


def stack_of(**services):
    """web plus the named services, each {image: OWN} updated with its own fields."""
    out = {"web": {"image": OWN}}
    for name, fields in services.items():
        out[name] = dict({"image": OWN}, **fields)
    return {"services": out}


def render(stack, catalog, env=None):
    return yaml.safe_load(render_module.render(APP, catalog, env or {}, stack))


def refusal(case, stack, catalog, env=None):
    """What render says when it refuses, asserting that it does (exit 2)."""
    err = StringIO()
    with redirect_stderr(err), case.assertRaises(SystemExit) as e:
        render(stack, catalog, env)
    case.assertEqual(e.exception.code, 2)
    return err.getvalue()


def unescape(value):
    return value.replace("$$", "$")


# -----------------------------------------------------------------------------
# TESTS
# -----------------------------------------------------------------------------

class Reservations(unittest.TestCase):
    def test_memory_is_reserved_at_its_limit_and_cpu_at_its_reservation(self):
        out = render(stack_of(), catalog_of(resources={"web": {"memoryMiB": 768, "cpus": 2.0, "pids": 64, "cpuMillis": 250}}))
        self.assertEqual(out["services"]["web"]["deploy"]["resources"], {
            "limits": {"memory": "768M", "cpus": "2.0", "pids": 64},
            "reservations": {"memory": "768M", "cpus": "0.25", "generic_resources": [
                {"discrete_resource_spec": {"kind": "HOMELAB_MEMORY_MIB", "value": 768}},
                {"discrete_resource_spec": {"kind": "HOMELAB_CPU_MILLIS", "value": 250}}]}})

    def test_unlisted_services_get_the_defaults(self):
        out = render(stack_of(worker={}), catalog_of())
        self.assertEqual(out["services"]["worker"]["deploy"]["resources"]["reservations"]["memory"], "512M")


class Admission(unittest.TestCase):
    def refuses(self, stack, catalog, says):
        self.assertIn(says, refusal(self, stack, catalog))

    def test_exactly_the_reservation_fits(self):
        # positive control of every refusal below: 2 x 512 MiB, 2 x 100 millicores
        render(stack_of(worker={}), catalog_of(memory=1024, cpu=200))

    def test_replicas_count(self):
        self.refuses(stack_of(worker={"deploy": {"replicas": 2}}), catalog_of(memory=1024, cpu=1000), "need 1536 MiB")

    def test_memory_above_the_reservation(self):
        self.refuses(stack_of(worker={}), catalog_of(memory=1023, cpu=1000), "need 1024 MiB")

    def test_cpu_above_the_reservation(self):
        self.refuses(stack_of(worker={}), catalog_of(memory=4096, cpu=199),
                     "need 200 millicores (web 100, worker 100), apps.demo.reservation.cpus holds 199 millicores")

    def test_excluded_services_hold_nothing(self):
        render(stack_of(grafana={}), catalog_of(memory=512, cpu=100, exclude=["grafana"]))

    def test_override_services_count(self):
        self.refuses(stack_of(), catalog_of(memory=512, cpu=1000, override={"services": {"relay": {"image": OWN}}}),
                     "need 1024 MiB (relay 512, web 512)")

    def test_stateful_services_count_once(self):
        stack = stack_of(db={"deploy": {"replicas": 3}, "volumes": ["data:/data"]})
        stack["volumes"] = {"data": {}}
        render(stack, catalog_of(memory=1024, cpu=200, stateful=["db"]))

    def test_the_refusal_names_the_numbers_and_the_knob(self):
        self.refuses(stack_of(worker={"deploy": {"replicas": 2}}), catalog_of(memory=1024, cpu=1000),
                     "the stack's tasks need 1536 MiB (web 512, worker 1024), apps.demo.reservation.memoryMiB holds "
                     "1024 MiB: raise it or lower apps.demo.resources")

    def test_services_are_bounded(self):
        many = {f"s{i}": {} for i in range(SERVICES_MAX)}
        self.refuses(stack_of(**many), catalog_of(memory=1 << 20, cpu=1 << 20), "5 services, more than the 4")
        render(stack_of(**{f"s{i}": {} for i in range(SERVICES_MAX - 1)}), catalog_of(memory=1 << 20, cpu=1 << 20))


class Placement(unittest.TestCase):
    def per_node(self, deploy):
        return render(stack_of(worker={"deploy": deploy}), catalog_of(memory=8192, cpu=4000))["services"]["worker"]["deploy"]

    def test_stateless_replicas_spread(self):
        self.assertEqual(self.per_node({"replicas": 3})["placement"]["max_replicas_per_node"], PER_NODE)

    def test_an_apps_lower_bound_stands_a_higher_one_is_capped(self):
        self.assertEqual(self.per_node({"placement": {"max_replicas_per_node": 1}})["placement"]["max_replicas_per_node"], 1)
        self.assertEqual(self.per_node({"placement": {"max_replicas_per_node": 9}})["placement"]["max_replicas_per_node"],
                         PER_NODE)

    def test_no_count_is_refused(self):
        for bad in (0, -1, "2", True):
            with self.subTest(bad=bad):
                self.assertIn("is no count", refusal(self, stack_of(worker={"deploy": {"placement": {"max_replicas_per_node": bad}}}),
                                                     catalog_of(memory=8192, cpu=4000)))

    def test_stateful_services_stay_on_the_state_worker(self):
        stack = stack_of(db={"volumes": ["data:/data"]})
        stack["volumes"] = {"data": {}}
        db = render(stack, catalog_of(stateful=["db"]))["services"]["db"]["deploy"]
        self.assertEqual(db["placement"], {"constraints": [render_module.STATE_CONSTRAINT]})


class Capabilities(unittest.TestCase):
    def test_every_capability_is_dropped(self):
        out = render(stack_of(worker={"cap_drop": ["NET_RAW"]}), catalog_of())
        for name in ("web", "worker"):
            self.assertEqual(out["services"][name]["cap_drop"], ["ALL"])
            self.assertNotIn("cap_add", out["services"][name])

    def test_an_entrypoint_gets_back_what_it_names(self):
        out = render(stack_of(worker={"cap_add": ["SETUID", "CHOWN"]}), catalog_of())
        self.assertEqual(out["services"]["worker"]["cap_add"], ["CHOWN", "SETUID"])

    def test_capabilities_outside_the_allow_list_are_refused(self):
        for caps in (["NET_RAW"], ["SYS_ADMIN"], ["CHOWN", "NET_ADMIN"], "CHOWN"):
            with self.subTest(caps=caps):
                self.assertIn("worker.cap_add", refusal(self, stack_of(worker={"cap_add": caps}), catalog_of()))


class Idle(unittest.TestCase):
    def test_a_stopped_app_renders_at_zero_replicas_and_is_admitted_at_its_own(self):
        stack = stack_of(worker={"deploy": {"replicas": 2}})
        rendered = render_module.render(APP, catalog_of(memory=2048, cpu=1000), {}, stack)
        stopped = yaml.safe_load(render_module.replicas_stop(rendered))
        self.assertEqual({n: s["deploy"]["replicas"] for n, s in stopped["services"].items()}, {"web": 0, "worker": 0})
        # everything else is the running app's: the image and limits update while it sleeps
        running = yaml.safe_load(rendered)
        for svc in running["services"].values():
            svc["deploy"]["replicas"] = 0
        self.assertEqual(stopped, running)
        self.assertIn("need 1536 MiB", refusal(self, stack, catalog_of(memory=1024, cpu=1000)))


class Tenant(unittest.TestCase):
    def test_every_service_of_a_telemetry_app_carries_its_tenant(self):
        out = render(stack_of(worker={}), catalog_of(tenant="app-demo"))
        for name in ("web", "worker"):
            self.assertEqual(out["services"][name]["environment"][OTLP], f"{HEADER}=app-demo")

    def test_an_apps_own_headers_are_kept(self):
        out = render(stack_of(worker={"environment": {OTLP: "authorization=Basic x"}}), catalog_of(tenant="app-demo"))
        self.assertEqual(unescape(out["services"]["worker"]["environment"][OTLP]), f"authorization=Basic x,{HEADER}=app-demo")

    def test_an_app_naming_a_tenant_is_refused(self):
        for value in (f"{HEADER}=app-other", "x-scope-orgid=app-other", f"a=b, {HEADER} = app-other"):
            with self.subTest(value=value):
                self.assertIn("the homelab sets the app's tenant",
                              refusal(self, stack_of(worker={"environment": {OTLP: value}}), catalog_of(tenant="app-demo")))
        self.assertIn("web.environment", refusal(self, stack_of(), catalog_of(tenant="app-demo"),
                                                 env={"web": {OTLP: f"{HEADER}=app-other"}}))

    def test_no_telemetry_no_tenant(self):
        out = render(stack_of(), catalog_of(tenant=None))
        self.assertNotIn("environment", out["services"]["web"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
