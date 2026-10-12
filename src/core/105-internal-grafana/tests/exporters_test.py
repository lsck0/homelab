"""vm-105's own exporters without a network: the inverter's (lib/fronius-exporter.py) and the spot price's
(lib/spot-price.py).

Usage: exporters_test.py <fronius-exporter.py> <spot-price.py> <out dir>

Fault injection at each one's boundary: a hung inverter endpoint, an energy-charts outage. Writes
<out dir>/fronius-<case>.prom, which tests/exporters.nix checks with promtool and tests/dashboards.nix reads as the
inverter's metric names.
"""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import threading
import time
import unittest

FRONIUS, SPOT_PRICE, OUT = sys.argv[1:4]
del sys.argv[1:4]
os.environ["SPOT_API"] = "http://spot.test/price"

import feed_io  # noqa: E402
from energy_fakes import FakeSpot, local_s  # noqa: E402


def module_load(path):
    name = os.path.splitext(os.path.basename(path))[0].replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def exposition(text):
    """{metric{labels}: value} of an exposition."""
    samples = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            name, value = line.rsplit(" ", 1)
            samples[name] = float(value)
    return samples


# ---- fronius exporter ---------------------------------------------------------------------------

fronius = module_load(FRONIUS)

FRONIUS_DAY = {
    "powerflow": {"Site": {"P_PV": 3500.5, "P_Grid": -1200.0, "P_Load": -2300.5, "P_Akku": -100.0,
                           "rel_Autonomy": 100.0, "rel_SelfConsumption": 65.7, "Meter_Location": "grid",
                           "E_Day": None, "E_Year": None, "E_Total": 12345678.0},
                  "Inverters": {"1": {"SOC": 55.0}}},
    # a full smart meter: every field the exporter reads, so the exposition names every meter metric
    "meter": {"0": {**{field.format(phase): 100.0 + i for i, field in enumerate(fronius.METER_PHASE)
                       for phase in fronius.PHASES},
                    **{f"Voltage_AC_PhaseToPhase_{pair}": 400.5 for pair in fronius.PHASE_PAIRS},
                    "Frequency_Phase_Average": 50.01,
                    "EnergyReal_WAC_Plus_Absolute": 4567890.0, "EnergyReal_WAC_Minus_Absolute": 1234567.0}},
    "storage": {"0": {"Controller": {"Temperature_Cell": 21.5, "Current_DC": -0.3, "Capacity_Maximum": 10240.0}}},
    "inverter": {"DeviceStatus": {"StatusCode": 7, "ErrorCode": 0}, "PAC": {"Value": 3400.0},
                 "UDC": {"Value": 610.0}, "IDC": {"Value": 5.8}},
}
FRONIUS_NIGHT_BATTERY_OFFLINE = {
    "powerflow": {"Site": {"P_PV": None, "P_Grid": 350.0, "P_Load": -350.0, "P_Akku": None,
                           "rel_Autonomy": None, "rel_SelfConsumption": None, "Meter_Location": "grid"},
                  "Inverters": {"1": {"SOC": None}}},
    "meter": FRONIUS_DAY["meter"],
    "storage": {},
    "inverter": {"DeviceStatus": {"StatusCode": 3, "ErrorCode": 0}, "PAC": {"Value": None}},
}
FRONIUS_HIDDEN_GENERATOR = {
    "powerflow": {"Site": {"P_PV": 1000.0, "P_Grid": -4500.0, "P_Load": 2000.0, "P_Akku": 0.0,
                           "Meter_Location": "grid"}, "Inverters": {}},
    "meter": FRONIUS_DAY["meter"], "storage": FRONIUS_DAY["storage"], "inverter": FRONIUS_DAY["inverter"],
}


def fronius_fake(case, hung=()):
    release = threading.Event()

    def fetch(path, timeout_s):
        key = next(k for k, p in fronius.ENDPOINTS.items() if p == path)
        if key in hung:
            release.wait(timeout_s + 5)
            return None
        return case.get(key)
    return fetch, release


class Fronius(unittest.TestCase):
    def scrape(self, name, case, hung=(), deadline_s=2.0):
        fetch, release = fronius_fake(case, hung)
        try:
            text = fronius.scrape(fetch, deadline_s)
        finally:
            release.set()
        with open(os.path.join(OUT, f"fronius-{name}.prom"), "w") as handle:
            handle.write(text)
        return exposition(text)

    def test_day(self):
        m = self.scrape("day", FRONIUS_DAY)
        self.assertEqual(m["fronius_pv_watts"], 3500.5)
        self.assertEqual(m["fronius_load_watts"], 2300.5)
        self.assertEqual(m["fronius_battery_soc_ratio"], 0.55)
        self.assertEqual(m['fronius_site_info{meter_location="grid"}'], 1.0)
        self.assertNotIn("fronius_inverter_energy_day_wh", m)
        self.assertTrue(all(m[f'fronius_up{{endpoint="{k}"}}'] == 1.0 for k in fronius.ENDPOINTS))

    def test_night_and_an_offline_battery_are_absent_not_zero(self):
        m = self.scrape("night", FRONIUS_NIGHT_BATTERY_OFFLINE)
        # pv at night is the one legitimate zero
        self.assertEqual(m["fronius_pv_watts"], 0.0)
        for absent in ("fronius_battery_watts", "fronius_battery_soc_ratio", "fronius_autonomy_ratio",
                       "fronius_inverter_ac_watts", "fronius_battery_temperature_celsius"):
            self.assertNotIn(absent, m)

    def test_a_hidden_generator_leaves_the_load_unknown(self):
        m = self.scrape("hidden-generator", FRONIUS_HIDDEN_GENERATOR)
        self.assertNotIn("fronius_load_watts", m)
        self.assertEqual(m["fronius_unaccounted_watts"], 2000.0)

    def test_a_hung_endpoint_misses_the_deadline_alone(self):
        started = time.monotonic()
        m = self.scrape("hung-meter", FRONIUS_DAY, hung=("meter",), deadline_s=0.3)
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertEqual(m['fronius_up{endpoint="meter"}'], 0.0)
        self.assertEqual(m['fronius_up{endpoint="powerflow"}'], 1.0)
        self.assertNotIn("fronius_meter_import_wh", m)
        self.assertIn("fronius_load_watts", m)

    def test_deadline_from_the_scrape_header(self):
        for header, deadline in ((None, 9.5), ("10", 9.5), ("4.5", 4.0), ("0", 9.5), ("junk", 9.5), ("0.2", 0.5)):
            with self.subTest(header=header):
                self.assertEqual(fronius.scrape_deadline_s(header), deadline)

    def test_label_values_are_escaped(self):
        m = fronius.Metrics()
        m.add("x", "help", 1, {"meter_location": 'a"b\\c\nd'})
        self.assertIn('x{meter_location="a\\"b\\\\c\\nd"} 1.0', m.render())


# ---- spot-price ---------------------------------------------------------------------------------

spot_price = module_load(SPOT_PRICE)


class SpotPrice(unittest.TestCase):
    def run_spot(self, tmp, now_s, fake):
        cache, out = os.path.join(tmp, "spot.json"), os.path.join(tmp, "spot.prom")
        with contextlib.redirect_stderr(io.StringIO()):
            rc = spot_price.run(cache, out, now_s, fake)
        with open(out) as handle:
            return rc, exposition(handle.read()), cache

    def test_spring_forward_day_from_one_cached_fetch(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeSpot()
            now_s = local_s(2026, 3, 29, 9, 20)
            self.assertEqual(self.run_spot(tmp, now_s, fake)[0], 0)
            rc, m, _ = self.run_spot(tmp, now_s + 900, fake)
            self.assertEqual(rc, 0)
            self.assertEqual(fake.calls, 1)
            # the hour of day prices it: 09:15 is 50 + 9 * 10 EUR/MWh; the 23 hour day runs 00 to 23
            self.assertAlmostEqual(m['energy_spot_price_eur_per_kwh{zone="DE-LU"}'], 0.14)
            self.assertAlmostEqual(m['energy_spot_price_today_eur_per_kwh{zone="DE-LU",stat="min"}'], 0.05)
            self.assertAlmostEqual(m['energy_spot_price_today_eur_per_kwh{zone="DE-LU",stat="max"}'], 0.28)
            self.assertEqual(m['energy_spot_price_available{zone="DE-LU"}'], 1.0)

    def test_an_outage_keeps_the_cache_and_says_so_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            now_s = local_s(2026, 6, 10, 12)
            self.run_spot(tmp, now_s, FakeSpot())
            # energy-charts down: the cached day still prices today
            down = FakeSpot(fail=True)
            rc, m, _ = self.run_spot(tmp, now_s + 900, down)
            self.assertEqual((rc, down.calls), (0, 0))
            self.assertEqual(m['energy_spot_price_available{zone="DE-LU"}'], 1.0)
            # past the cached days: no price, never a stale one, and no failed run, only the gauge
            rc, m, cache = self.run_spot(tmp, local_s(2026, 6, 13, 12), down)
            self.assertEqual(rc, 0)
            self.assertEqual(m, {'energy_spot_price_available{zone="DE-LU"}': 0.0})
            self.assertTrue(feed_io.file_json_load(cache)["slots"], "the outage emptied the cache")
            # back: it recovers on its own at the next attempt, an hour after the failed one
            back = FakeSpot()
            rc, m, _ = self.run_spot(tmp, local_s(2026, 6, 13, 12, 15), back)
            self.assertEqual((back.calls, m['energy_spot_price_available{zone="DE-LU"}']), (0, 0.0))
            rc, m, _ = self.run_spot(tmp, local_s(2026, 6, 13, 13, 15), back)
            self.assertEqual((back.calls, m['energy_spot_price_available{zone="DE-LU"}']), (1, 1.0))


if __name__ == "__main__":
    unittest.main()
