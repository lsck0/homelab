"""An app's own dashboards as lib/dashboards-import.py makes them the app's, table by table.

Usage: dashboards_import_test.py <path to dashboards-import.py>
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("dashboards_import", sys.argv.pop(1))
imp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(imp)

APP = "demo"


def board(datasource, **extra):
    out = {"uid": "main", "title": "Main", "panels": [{"type": "timeseries", "datasource": datasource,
                                                      "targets": [{"datasource": datasource, "expr": "up"}]}]}
    out.update(extra)
    return json.dumps(out)


def normalise(text, name="dash/main.json"):
    return imp.dashboard_normalise(APP, name, text)


class Normalise(unittest.TestCase):
    def test_references_become_the_apps_own(self):
        for ref, want in [
            ({"type": "prometheus", "uid": "abc"}, {"type": "prometheus", "uid": "prometheus"}),
            ({"type": "loki", "uid": "loki"}, {"type": "loki", "uid": "loki-demo"}),
            ({"type": "loki", "uid": "loki-other"}, {"type": "loki", "uid": "loki-demo"}),
            ({"type": "tempo", "uid": "tempo-other"}, {"type": "tempo", "uid": "tempo-demo"}),
            ("Loki", {"type": "loki", "uid": "loki-demo"}),
            ("Pyroscope", {"type": "grafana-pyroscope-datasource", "uid": "pyroscope-demo"}),
            ("-- Grafana --", "-- Grafana --"),
            ("$ds", "$ds"),
        ]:
            with self.subTest(ref=ref):
                out = normalise(board(ref))
                self.assertEqual(out["panels"][0]["datasource"], want)
                self.assertEqual(out["panels"][0]["targets"][0]["datasource"], want)

    def test_export_inputs_resolve_to_the_apps_own(self):
        text = board("${DS_LOKI}", __inputs=[{"name": "DS_LOKI", "pluginId": "loki", "type": "datasource"}],
                     __requires=[{"id": "loki"}], id=7)
        out = normalise(text)
        self.assertEqual(out["panels"][0]["datasource"], {"type": "loki", "uid": "loki-demo"})
        self.assertNotIn("__inputs", out)
        self.assertNotIn("id", out)

    def test_datasource_variables_list_only_the_apps_own(self):
        text = board("$ds", templating={"list": [{"name": "ds", "type": "datasource", "query": "loki"}]})
        self.assertEqual(normalise(text)["templating"]["list"][0]["regex"], "^loki-demo$")

    def test_uid_is_prefixed_and_bounded(self):
        self.assertEqual(normalise(board("Loki"))["uid"], "demo-main")
        self.assertEqual(normalise(json.dumps({"panels": []}), "x/errors.json")["uid"], "demo-errors")
        self.assertEqual(len(normalise(json.dumps({"uid": "u" * 60, "panels": []}))["uid"]), imp.UID_LENGTH_MAX)

    def test_refusals(self):
        for text, says in [
            (board({"type": "postgres", "uid": "pg"}), "only"),
            (board("Postgres"), "only"),
            (board(42), "neither"),
            (board("$ds", templating={"list": [{"type": "datasource", "query": "mysql"}]}), "datasource variable"),
            ("{nope", "not json"),
            ("[]", "not a dashboard"),
            (json.dumps({"panels": [], "pad": "x" * imp.DASHBOARD_BYTES_MAX}), "larger than"),
        ]:
            with self.subTest(says=says), self.assertRaises(imp.Refused) as e:
                normalise(text)
            self.assertIn(says, str(e.exception))


class Import(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.checkout = os.path.join(self.dir.name, "repo")
        self.out = os.path.join(self.dir.name, "share", "dashboards")
        os.makedirs(os.path.join(self.checkout, "dash"))
        # the share exists, its dashboards root not yet: the first import makes it
        os.makedirs(os.path.dirname(self.out))

    def tearDown(self):
        self.dir.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.checkout, name), "w", encoding="utf-8") as f:
            f.write(text)

    def test_the_folder_is_replaced_whole_and_kept_on_a_refusal(self):
        self.write("dash/a.json", board("Loki", uid="a"))
        self.write("dash/b.json", board("Loki", uid="b"))
        self.assertEqual(imp.dashboards_import(APP, self.checkout, self.out, ["dash/*.json"]), ["demo-a", "demo-b"])
        os.remove(os.path.join(self.checkout, "dash/b.json"))
        imp.dashboards_import(APP, self.checkout, self.out, ["dash/*.json"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, APP))), ["demo-a.json"])
        self.write("dash/c.json", "{broken")
        with self.assertRaises(imp.Refused) as e:
            imp.dashboards_import(APP, self.checkout, self.out, ["dash/*.json"])
        self.assertIn("dash/c.json", str(e.exception))
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, APP))), ["demo-a.json"])

    def test_nothing_from_outside_the_checkout(self):
        os.symlink("/etc/passwd", os.path.join(self.checkout, "dash/evil.json"))
        with self.assertRaises(imp.Refused) as e:
            imp.dashboards_import(APP, self.checkout, self.out, ["dash/*.json"])
        self.assertIn("outside the checkout", str(e.exception))


if __name__ == "__main__":
    unittest.main(verbosity=1)
