"""The energy model and this terminal's feed scripts, without a network.

Usage: feeds_test.py <scripts dir> <out dir>

Table cases for the edges, hypothesis properties for the laws (local days tile the year, the cheapest window is the
brute-force one), and fault injection at the one boundary every script has, urlopen: refused connections,
prometheus errors, partial answers. Every clock is a parameter, every random draw comes from hypothesis' seed.

Writes <out dir>/payloads/<name>.json, what the scripts publish for each TRMNL template (tests/trmnl-templates.nix
renders them).
"""
import contextlib
import datetime
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse

from hypothesis import given, settings
from hypothesis import strategies as st

SCRIPTS, OUT = sys.argv[1:3]
del sys.argv[1:3]
PAYLOADS = os.path.join(OUT, "payloads")
os.makedirs(PAYLOADS, exist_ok=True)

PROMETHEUS_TEST = "http://prometheus.test"
os.environ["ENERGY_PROMETHEUS"] = PROMETHEUS_TEST
os.environ["ENERGY_SPOT_API"] = "http://spot.test/price"

import energy_model as em  # noqa: E402
from energy_fakes import BERLIN, FakeSpot, Response, json_response, local_s  # noqa: E402

SPRING_FORWARD = datetime.date(2026, 3, 29)
FALL_BACK = datetime.date(2026, 10, 25)
HOUR = 3600
DAY = 86400
# hypothesis: deterministic, and quick enough for every check run
PROPERTY = settings(max_examples=200, deadline=None, derandomize=True)


def module_load(path):
    name = os.path.splitext(os.path.basename(path))[0].replace("-", "_")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def script_load(name):
    return module_load(os.path.join(SCRIPTS, f"{name}.py"))


def text_read(path):
    with open(path) as handle:
        return handle.read()


def payload_write(name, payload):
    with open(os.path.join(PAYLOADS, f"{name}.json"), "w") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)


# ---- fakes at the urlopen boundary --------------------------------------------------------------

class FakePrometheus:
    """Answers batched queries (energy_model.query_batch) term by term from `values`; `fail` injects a fault.

    fail: None, "refused" (URLError), "error" (status error), "garbage" (not json), or a set of term names to leave
    out of every answer (a partial result).
    """

    TERM = re.compile(r'"term", "([a-z0-9_]+)"')

    def __init__(self, values=None, default=1.0, fail=None):
        self.values, self.default, self.fail = values or {}, default, fail
        self.queries = []

    def __call__(self, request, timeout):
        url = request.full_url if hasattr(request, "full_url") else request
        form = urllib.parse.parse_qs((request.data or b"").decode()) if hasattr(request, "data") else {}
        query = form.get("query", [""])[0]
        self.queries.append(query)
        if self.fail == "refused":
            raise urllib.error.URLError("connection refused")
        if self.fail == "garbage":
            return Response(b"<html>bad gateway</html>")
        if self.fail == "error":
            return json_response({"status": "error", "error": "query timed out"})
        missing = self.fail if isinstance(self.fail, set) else set()
        terms = [t for t in self.TERM.findall(query) if t not in missing]
        if url.endswith("/api/v1/query_range"):
            start, end, step = (float(form[k][0]) for k in ("start", "end", "step"))
            result = [{"metric": {"term": t}, "values": [[start + i * step, str(self.value(t))]
                                                         for i in range(int((end - start) // step) + 1)]}
                      for t in terms]
            return json_response({"status": "success", "data": {"resultType": "matrix", "result": result}})
        result = [{"metric": {"term": t}, "value": [0, str(self.value(t))]} for t in terms]
        return json_response({"status": "success", "data": {"resultType": "vector", "result": result}})

    def value(self, term):
        return self.values.get(term, self.default)


# ---- energy model -------------------------------------------------------------------------------

class LocalDays(unittest.TestCase):
    def test_dst_days_are_23_and_25_hours(self):
        for day, hours in ((SPRING_FORWARD, 23), (FALL_BACK, 25), (datetime.date(2026, 6, 1), 24)):
            start, end = em.local_day_bounds(day)
            self.assertEqual(end - start, hours * HOUR, day)
            self.assertEqual(datetime.datetime.fromtimestamp(start, BERLIN).hour, 0)

    @PROPERTY
    @given(st.dates(min_value=datetime.date(2000, 1, 1), max_value=datetime.date(2099, 12, 30)))
    def test_days_tile_time(self, day):
        _, end = em.local_day_bounds(day)
        start_next, _ = em.local_day_bounds(day + datetime.timedelta(days=1))
        self.assertEqual(end, start_next)

    def test_a_year_of_days_and_of_months_is_a_year(self):
        days = sum(e - s for s, e in (em.local_day_bounds(datetime.date(2026, 1, 1) + datetime.timedelta(days=i))
                                      for i in range(365)))
        months = sum(e - s for s, e in (em.local_month_bounds(2026, m) for m in range(1, 13)))
        self.assertEqual(days, 365 * DAY)
        self.assertEqual(months, 365 * DAY)

    def test_today_follows_the_house_clock(self):
        # 23:30 utc on 2026-06-01 is already the 2nd in Berlin
        self.assertEqual(em.local_today(int(datetime.datetime(2026, 6, 1, 23, 30, tzinfo=datetime.timezone.utc)
                                            .timestamp())), datetime.date(2026, 6, 2))


class Queries(unittest.TestCase):
    def test_batch_tags_every_term_and_parses_back(self):
        terms = em.cost_terms(em.window_from_seconds(DAY, at_s=1767225600))
        query = em.query_batch(terms)
        self.assertEqual(sorted(FakePrometheus.TERM.findall(query)), sorted(terms))
        rows = [{"metric": {"term": t}, "value": [0, "2.5"]} for t in terms]
        self.assertEqual(em.query_batch_parse(rows), {t: 2.5 for t in terms})

    def test_batch_parse_drops_malformed_rows(self):
        rows = [{"metric": {"term": "a"}, "value": [0, "NaN?"]}, {"metric": {}}, {"value": [0, "1"]},
                {"metric": {"term": "b"}, "value": [0, "4"]}]
        self.assertEqual(em.query_batch_parse(rows), {"b": 4.0, None: 1.0})

    def test_window_pins_every_selector_to_its_end(self):
        window = em.window_from_seconds(23 * HOUR, at_s=1774821600)
        for name, expr in em.energy_terms(window).items():
            self.assertIn("@ 1774821600", expr, name)
            self.assertIn("[82800s", expr, name)

    def test_meter_rise_is_last_minus_minimum(self):
        expr = em.meter_rise(em.GAS_M3, em.WINDOW_RANGE)
        self.assertIn(f"last_over_time({em.GAS_M3}[$__range])", expr)
        self.assertIn(f"min_over_time({em.GAS_M3}[$__range])", expr)
        self.assertNotIn("max_over_time", expr)

    def test_a_tariff_at_zero_is_unset(self):
        self.assertTrue(em.tariff("price_gas").endswith("> 0)"))
        with self.assertRaises(AssertionError):
            em.tariff("price_beer")

    def test_period_terms_are_energy_or_cost_terms(self):
        known = em.energy_terms(em.WINDOW_RANGE) | em.cost_terms(em.WINDOW_RANGE)
        self.assertLessEqual(set(em.PERIOD_TERMS), set(known))


class Spot(unittest.TestCase):
    def slots(self, day, step=900):
        start, end = em.local_day_bounds(day)
        return [(t, 0.1 + (t - start) / DAY) for t in range(start, end, step)]

    def test_fetch_due(self):
        today = datetime.date(2026, 6, 10)
        both = self.slots(today) + self.slots(today + datetime.timedelta(days=1))
        cases = [
            ("no cache", None, local_s(2026, 6, 10, 9), True),
            ("today complete before publication", {"attempted_at_s": 0, "slots": self.slots(today)},
             local_s(2026, 6, 10, 9), False),
            ("tomorrow published", {"attempted_at_s": 0, "slots": self.slots(today)}, local_s(2026, 6, 10, 14), True),
            ("tomorrow tried within the hour", {"attempted_at_s": local_s(2026, 6, 10, 13, 30),
                                                "slots": self.slots(today)}, local_s(2026, 6, 10, 14), False),
            ("both days held", {"attempted_at_s": 0, "slots": both}, local_s(2026, 6, 10, 20), False),
            ("today missing after midnight", {"attempted_at_s": 0, "slots": self.slots(today)},
             local_s(2026, 6, 11, 0, 5), True),
            ("failed fetch retried after an hour", {"attempted_at_s": local_s(2026, 6, 10, 8), "slots": []},
             local_s(2026, 6, 10, 9), True),
            ("failed fetch not retried within the hour", {"attempted_at_s": local_s(2026, 6, 10, 8, 30), "slots": []},
             local_s(2026, 6, 10, 9), False),
        ]
        for name, cache, now_s, due in cases:
            with self.subTest(name):
                self.assertEqual(em.spot_cache_fetch_due(cache, now_s), due)

    def test_current_slot(self):
        quarter = self.slots(datetime.date(2026, 6, 10))
        hourly = self.slots(datetime.date(2026, 6, 10), HOUR)
        noon = local_s(2026, 6, 10, 12, 7)
        self.assertEqual(em.spot_current(quarter, noon), dict(quarter)[local_s(2026, 6, 10, 12)])
        self.assertEqual(em.spot_current(hourly, noon), dict(hourly)[local_s(2026, 6, 10, 12)])
        # the last quarter hour lasts a quarter hour, the last hour an hour
        self.assertIsNone(em.spot_current(quarter, local_s(2026, 6, 11, 0, 1)))
        self.assertIsNotNone(em.spot_current(hourly, local_s(2026, 6, 10, 23, 59)))
        self.assertIsNone(em.spot_current([], noon))

    def test_day_stats_cover_the_short_day_only(self):
        slots = self.slots(SPRING_FORWARD - datetime.timedelta(days=1)) + self.slots(SPRING_FORWARD)
        start, end = em.local_day_bounds(SPRING_FORWARD)
        stats = em.spot_day_stats(slots, start, end)
        self.assertEqual(len([t for t, _ in slots if start <= t < end]), 23 * 4)
        self.assertEqual(stats[0], dict(slots)[start])

    def test_parse_rejects_malformed(self):
        self.assertIsNone(em.spot_parse({"unix_seconds": [1, 2], "price": [1.0]}))
        self.assertIsNone(em.spot_parse("not a dict"))
        self.assertEqual(em.spot_parse({"unix_seconds": [2, 1], "price": [2000.0, None]}), [(2, 2.0)])

    @PROPERTY
    @given(st.lists(st.floats(min_value=-0.5, max_value=2.0, allow_nan=False), min_size=1, max_size=30),
           st.integers(min_value=1, max_value=6))
    def test_cheapest_window_is_the_brute_force_one(self, prices, hours):
        hourly = [(i * HOUR, p) for i, p in enumerate(prices)]
        best = em.spot_cheapest_window(hourly, hours)
        runs = [(hourly[i][0], sum(p for _, p in hourly[i:i + hours]) / hours) for i in range(len(prices) - hours + 1)]
        if not runs:
            self.assertIsNone(best)
            return
        self.assertAlmostEqual(best[1], min(mean for _, mean in runs))

    def test_cheapest_window_skips_a_gap(self):
        hourly = [(0, 0.0), (HOUR, 0.0), (5 * HOUR, 1.0), (6 * HOUR, 1.0)]
        self.assertEqual(em.spot_cheapest_window(hourly, 2), (0, 0.0))
        self.assertIsNone(em.spot_cheapest_window([(0, 0.0), (2 * HOUR, 0.0)], 2))


# ---- energy-sync --------------------------------------------------------------------------------

energy_sync = script_load("energy-sync")


class EnergySync(unittest.TestCase):
    def run_sync(self, now_s, prometheus, state=None):
        tmp = state or tempfile.mkdtemp()
        feed, state_dir = os.path.join(tmp, "feed"), os.path.join(tmp, "state")
        os.makedirs(state_dir, exist_ok=True)
        with contextlib.redirect_stderr(io.StringIO()):
            rc = energy_sync.run(feed, state_dir, now_s, lambda request, timeout: (
                FakeSpot()(request, timeout) if isinstance(request, str) else prometheus(request, timeout)))
        with open(os.path.join(feed, "energy.json")) as handle:
            payload = json.load(handle)
        return rc, payload, tmp

    def test_payload_and_exports(self):
        now_s = local_s(2026, 10, 25, 18, 30)
        values = {"net_eur": 4.257, "savings_eur": 1.5, "pv_kwh": 12.34, "load_kwh": 8.0,
                  "import_known_load_kwh": 2.0, "export_known_pv_kwh": 6.0, "gas_reading": 3278.0,
                  "gas_read_at": now_s - 40 * HOUR, "water_read_at": now_s - HOUR}
        rc, payload, tmp = self.run_sync(now_s, FakePrometheus(values))
        self.assertEqual(rc, 0)
        self.assertTrue(payload["source_ok"])
        self.assertEqual(payload["today"]["cost"], "4,26")
        self.assertEqual(payload["today"]["autarky"], "75 %")
        self.assertEqual(payload["gas"]["reading"], "3.278,000")
        self.assertTrue(payload["gas"]["stale"])
        self.assertFalse(payload["water"]["stale"])
        self.assertEqual(len(payload["history"]["days"]), energy_sync.HISTORY_DAYS)
        self.assertEqual(payload["history"]["days"][-1]["label"], "Sa")
        self.assertEqual(len(payload["spot"]["hours"]), energy_sync.SPOT_HOURS_SHOWN)
        payload_write("energy", payload)

        prom = text_read(os.path.join(tmp, "state", "energy.prom"))
        days = set(re.findall(r'day="([0-9-]+)"', prom))
        # the backfill fills the visible month in one run; today is shown as far as it goes
        self.assertEqual(len(days), em.PERIOD_COUNTS["day"] + 1)
        self.assertIn('homelab_energy_day_kwh{day="2026-10-25",flow="pv"}', prom)
        self.assertIn('homelab_energy_month_eur{month="2026-10",part="feed_in"}', prom)
        cached = json.loads(text_read(os.path.join(tmp, "state", "days.json")))["days"]
        self.assertEqual(len(cached), energy_sync.DAYS_BACKFILL_MAX)

    def test_a_completed_day_is_queried_once(self):
        now_s = local_s(2026, 10, 25, 18, 30)
        prometheus = FakePrometheus()
        _, _, tmp = self.run_sync(now_s, prometheus)
        prometheus.queries.clear()
        self.run_sync(now_s + 300, prometheus, tmp)
        days_queried = [q for q in prometheus.queries if '"term", "base_fees_eur"' in q and "net_eur" not in q]
        # the second run backfills older days only, never one it holds
        cached = json.loads(text_read(os.path.join(tmp, "state", "days.json")))["days"]
        self.assertEqual(len(days_queried), energy_sync.DAYS_BACKFILL_MAX)
        self.assertEqual(len(cached), 2 * energy_sync.DAYS_BACKFILL_MAX)

    def test_unreachable_prometheus_prints_dashes(self):
        for fault in ("refused", "error", "garbage"):
            with self.subTest(fault):
                rc, payload, tmp = self.run_sync(local_s(2026, 6, 10, 12), FakePrometheus(fail=fault))
                self.assertEqual(rc, 1)
                self.assertFalse(payload["source_ok"])
                self.assertEqual(payload["today"]["cost"], "-")
                self.assertEqual(payload["now"]["pv"], "-")
                self.assertEqual(payload["forecast"]["month"], "-")
                self.assertEqual(json.loads(text_read(os.path.join(tmp, "state", "days.json")))["days"], {})

    def test_a_missing_tariff_is_counted(self):
        missing = {f"tariff_{key}" for key in ("price_gas", "fee_water")} | {"net_eur"}
        rc, payload, _ = self.run_sync(local_s(2026, 6, 10, 12), FakePrometheus(fail=missing))
        self.assertEqual(rc, 0)
        self.assertEqual(payload["prices_missing"], 2)
        self.assertEqual(payload["today"]["cost"], "-")

    def test_days_due_stops_at_the_bound_and_skips_the_running_day(self):
        today = datetime.date(2026, 10, 25)
        due = energy_sync.days_due({}, today, local_s(2026, 10, 25, 0, 1))
        self.assertEqual(len(due), energy_sync.DAYS_BACKFILL_MAX)
        # 00:01 is within the settle time of yesterday's end
        self.assertEqual(due[0], datetime.date(2026, 10, 23))

    def test_months_sum_their_days(self):
        days = {"2026-09-30": {"pv_kwh": 1.0}, "2026-10-01": {"pv_kwh": 2.0, "gas_m3": 1.5},
                "2026-10-02": {"pv_kwh": 3.0}}
        self.assertEqual(energy_sync.months_from_days(days),
                         {"2026-09": {"pv_kwh": 1.0}, "2026-10": {"pv_kwh": 5.0, "gas_m3": 1.5}})

    def test_german_numbers_round_trip(self):
        for value, digits, text in ((1234.5, 1, "1.234,5"), (-0.04, 2, "-0,04"), (1e6, 0, "1.000.000"),
                                    (None, 2, "-")):
            self.assertEqual(energy_sync.format_decimal(value, digits), text)

    @PROPERTY
    @given(st.floats(min_value=-1e7, max_value=1e7, allow_nan=False), st.integers(min_value=0, max_value=3))
    def test_german_decimal_parses_back(self, value, digits):
        text = energy_sync.format_decimal(value, digits)
        self.assertAlmostEqual(float(text.replace(".", "").replace(",", ".")), round(value, digits), places=digits)

    @PROPERTY
    @given(st.lists(st.tuples(st.floats(min_value=0, max_value=DAY), st.floats(min_value=-500, max_value=20000)),
                    max_size=50), st.floats(min_value=1, max_value=20000), st.booleans())
    def test_chart_path_stays_in_the_viewbox(self, points, top, close):
        d = energy_sync.chart_path(sorted(points), 0, DAY, top, close)
        for x, y in re.findall(r"(-?[0-9.]+),(-?[0-9.]+)", d):
            self.assertTrue(0 <= float(x) <= energy_sync.CHART_WIDTH_PX and 0 <= float(y) <= energy_sync.CHART_HEIGHT_PX)

    def test_formats(self):
        for watts, text in ((None, "-"), (0, "0 W"), (999.4, "999 W"), (1000, "1,00 kW"), (-2500, "-2,50 kW")):
            self.assertEqual(energy_sync.format_power(watts), text)
        for seconds, text in ((None, "nie"), (59, "vor 0 min"), (3600, "vor 1 h"), (90000, "vor 1 d")):
            self.assertEqual(energy_sync.format_age(seconds), text)


# ---- stats-sync ---------------------------------------------------------------------------------

stats_sync = script_load("stats-sync")


class StatsSync(unittest.TestCase):
    def test_human_units(self):
        for value, text in ((0, "0B/s"), (9.4, "9B/s"), (2048, "2.0K/s"), (50 * 1024 ** 2, "50M/s")):
            self.assertEqual(stats_sync.human_rate(value), text)
        for value, text in ((5, "5B"), (1536, "1.5KB"), (3 * 1024 ** 4, "3.0TB")):
            self.assertEqual(stats_sync.human_size(value), text)
        for value, text in ((999, "999"), (1500, "1.5k"), (25000, "25k"), (2.5e6, "2.5M")):
            self.assertEqual(stats_sync.human_count(value), text)
        for seconds, pct, text in ((0, 50, ""), (stats_sync.ETA_UNKNOWN_S, 10, ""), (120, 10, "2m"), (7200, 10, "2h"),
                                   (172800, 10, "2d"), (5, 100, "done")):
            self.assertEqual(stats_sync.eta(seconds, pct), text)

    def test_bars_scale_to_the_largest(self):
        rows = stats_sync.bars([("a", 10), ("b", 5), ("c", 0)])
        self.assertEqual([r["pct"] for r in rows], [100, 50, 0])

    def test_payload_names_guests_like_grafana_and_hides_torrent_names(self):
        inventory = {"121": {"name": "121-internal-paperless", "vm": "paperless", "powered": True, "idle": None},
                     "150": {"name": "150-apps-swarm", "vm": "swarm-150", "powered": True, "idle": None},
                     "126": {"name": "126-internal-huginn", "vm": "huginn", "powered": False, "idle": None}}
        with tempfile.TemporaryDirectory() as tmp:
            inv = os.path.join(tmp, "inventory.json")
            with open(inv, "w") as handle:
                json.dump(inventory, handle)

            def promql(query):
                if query.startswith("up{"):
                    return [{"metric": {"vm": "paperless"}, "value": [0, "1"]},
                            {"metric": {"vm": "swarm-150"}, "value": [0, "0"]}]
                return []

            listing = [{"name": "Secret.Movie.2026.2160p", "category": "radarr", "state": "downloading",
                        "progress": 0.5, "dlspeed": 1000, "size": 10 ** 9, "eta": 600}]
            patches = {"INVENTORY": inv, "promql": promql, "logql": lambda query: [],
                       "qb_get": lambda path: listing if "info" in path and "torrents" in path else {}}
            saved = {k: getattr(stats_sync, k) for k in patches}
            try:
                for k, v in patches.items():
                    setattr(stats_sync, k, v)
                rows, summary = stats_sync.services()
                torrents = stats_sync.torrents()
                payload = {"view": "stats", "generated_at": "2026-10-06T12:00:00+02:00", "label": "Tue 06 Oct 12:00",
                           "summary": summary, "services": rows, "services_more": 0,
                           "services_off": [r["name"] for r in rows if r["disabled"]],
                           "network": stats_sync.network(), "totals": stats_sync.totals(),
                           "requests": stats_sync.requests(), "clients": stats_sync.clients(),
                           "storage": stats_sync.storage(), "torrents": torrents}
            finally:
                for k, v in saved.items():
                    setattr(stats_sync, k, v)
        self.assertEqual([r["name"] for r in rows], ["paperless", "huginn", "swarm-150"])
        self.assertEqual(summary["down"], ["swarm-150"])
        self.assertEqual(torrents["items"][0]["name"], "radarr")
        payload_write("stats", payload)


# ---- calendar-sync ------------------------------------------------------------------------------

calendar_sync = script_load("calendar-sync")

ICS = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//test//EN
BEGIN:VEVENT
UID:dst
DTSTART;TZID=Europe/Berlin:20261025T003000
DTEND;TZID=Europe/Berlin:20261025T030000
SUMMARY:Night over the clock change
END:VEVENT
BEGIN:VEVENT
UID:hostile
DTSTART;TZID=Europe/Berlin:20261026T100000
DTEND;TZID=Europe/Berlin:20261026T113000
SUMMARY:<script>alert(1)</script> p<q & "quotes"
LOCATION:<img src=//tracker>
DESCRIPTION:secret meeting link https://meet.example/abc
END:VEVENT
BEGIN:VEVENT
UID:overlap
DTSTART;TZID=Europe/Berlin:20261026T103000
DTEND;TZID=Europe/Berlin:20261026T120000
SUMMARY:Overlapping
END:VEVENT
BEGIN:VEVENT
UID:allday
DTSTART;VALUE=DATE:20261027
DTEND;VALUE=DATE:20261028
SUMMARY:All day
END:VEVENT
END:VCALENDAR
"""

timed_event = st.tuples(st.integers(min_value=0, max_value=1439), st.integers(min_value=1, max_value=600))


class CalendarSync(unittest.TestCase):
    def test_minutes_into_the_dst_days_follow_the_wall_clock(self):
        # the grid is a wall clock with hour labels: 03:00 sits on the 03:00 line on the 23 h and the 25 h day
        for day in (FALL_BACK, SPRING_FORWARD):
            at = datetime.datetime(day.year, day.month, day.day, 3, 0, tzinfo=BERLIN)
            self.assertEqual(calendar_sync.minutes_into(day, at), 180, day)

    @PROPERTY
    @given(st.lists(timed_event, max_size=25))
    def test_lanes_never_overlap_and_fit_the_densest_moment(self, events):
        rows = [{"start_min": s, "end_min": min(1440, s + d)} for s, d in events]
        timed = calendar_sync.assign_lanes(rows)
        for a in timed:
            for b in timed:
                if a is not b and a["lane"] == b["lane"]:
                    self.assertTrue(a["end_min"] <= b["start_min"] or b["end_min"] <= a["start_min"])
        for e in timed:
            concurrent = sum(1 for o in timed if o["start_min"] <= e["start_min"] < o["end_min"])
            self.assertGreaterEqual(e["lanes"], concurrent)

    @PROPERTY
    @given(st.lists(st.tuples(st.floats(min_value=0, max_value=100), st.floats(min_value=0, max_value=100),
                              st.integers(min_value=0, max_value=3)), max_size=20),
           st.floats(min_value=0.5, max_value=30))
    def test_min_height_keeps_every_block_inside(self, blocks, min_pct):
        events = [{"top_pct": t, "height_pct": h, "lane": lane} for t, h, lane in blocks]
        calendar_sync.enforce_min_height(events, min_pct)
        for e in events:
            self.assertGreaterEqual(e["top_pct"], 0.0)
            self.assertLessEqual(round(e["top_pct"] + e["height_pct"], 2), 100.0)

    def test_views_and_the_private_ics(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = os.path.join(tmp, "private.ics")
            with open(source, "w") as handle:
                handle.write(ICS)
            sources = os.path.join(tmp, "sources")
            with open(sources, "w") as handle:
                handle.write(f"proton|file://{source}\n")
            views, ics = os.path.join(tmp, "views"), os.path.join(tmp, "ics")
            os.environ["CALENDAR_SOURCES"] = sources
            argv = sys.argv
            sys.argv = ["calendar-sync", views, ics]
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(calendar_sync.main(), 0)
            finally:
                sys.argv = argv
            self.assertIn("secret meeting link", text_read(os.path.join(ics, "merged.ics")))
            for name in os.listdir(views):
                self.assertNotIn("meet.example", text_read(os.path.join(views, name)), name)

    def test_week_view_on_the_long_day(self):
        calendars = [("proton", calendar_sync.Calendar.from_ical(ICS))]
        grid = calendar_sync.week(calendars, 0, FALL_BACK)
        sunday = next(d for d in grid["days"] if d["date"] == "2026-10-25")
        night = next(e for e in sunday["events"] if e["summary"].startswith("Night"))
        # drawn from the 00:30 line to the 03:00 line, though the 25 h day makes it three and a half hours long
        self.assertEqual((night["start_min"], night["end_min"]), (30, 180))
        self.assertTrue(grid["label"].isascii(), grid["label"])
        hostile = calendar_sync.week(calendars, 1, FALL_BACK)
        self.assertEqual(hostile["days"][0]["max_lanes"], 2)
        # the views the templates render: the week and the day holding the hostile invite, the month
        payload_write("calendar-week", hostile)
        payload_write("calendar-day", calendar_sync.day_view(calendars, 1, FALL_BACK))
        payload_write("calendar-month", calendar_sync.month_view(calendars, 0, FALL_BACK))


# ---- github-sync --------------------------------------------------------------------------------

github_sync = script_load("github-sync")

GITHUB_NOW = datetime.datetime(2026, 10, 6, 12, 0, tzinfo=datetime.timezone.utc)
GITHUB_REPOS = [
    {"name": "homelab", "private": False, "language": "Nix", "stargazers_count": 2, "pushed_at": "2026-10-06T09:00:00Z"},
    {"name": "diary", "private": True, "language": "Markdown", "stargazers_count": 0, "pushed_at": "2026-10-05T12:00:00Z"},
    {"name": "repo<a>", "private": False, "language": None, "stargazers_count": 0, "pushed_at": "bogus"},
]
GITHUB_NOTES = [
    {"reason": "ci_activity", "repository": {"name": "homelab", "private": False}, "updated_at": "2026-10-06T10:00:00Z",
     "subject": {"title": "<script>x</script> workflow run failed"}},
    {"reason": "ci_activity", "repository": {"name": "diary", "private": True}, "updated_at": "2026-10-06T11:00:00Z",
     "subject": {"title": "secret workflow run failed"}},
    {"reason": "mention", "repository": {"name": "diary", "private": True}},
    {"reason": "mention", "repository": {"name": "homelab", "private": False}},
]
GITHUB_ISSUES = {"total_count": 1, "items": [{"repository_url": "https://api.github.com/repos/lsck0/homelab",
                                              "title": "Title from a stranger <img src=x>", "created_at": "2026-10-04T12:00:00Z"}]}


class GithubSync(unittest.TestCase):
    def test_private_repos_stay_off_the_panel(self):
        payload = github_sync.payload_build(GITHUB_REPOS, GITHUB_NOTES, GITHUB_ISSUES, {"total_count": 0}, 3, 20,
                                            GITHUB_NOW, include_private=False)
        text = json.dumps(payload)
        self.assertNotIn("diary", text)
        self.assertNotIn("secret", text)
        self.assertEqual((payload["repos"], payload["ci_failing"], payload["alerts"]), (2, 1, 1))
        self.assertEqual(payload["active_a"][0]["age"], "3h")
        payload_write("github", payload)

    def test_private_repos_when_opted_in(self):
        payload = github_sync.payload_build(GITHUB_REPOS, GITHUB_NOTES, GITHUB_ISSUES, {"total_count": 0}, 3, 20,
                                            GITHUB_NOW, include_private=True)
        self.assertEqual((payload["repos"], payload["ci_failing"], payload["alerts"]), (3, 2, 2))

    def test_a_repo_without_the_private_field_counts_as_private(self):
        self.assertFalse(github_sync.public({"name": "x"}, False))
        self.assertFalse(github_sync.public(None, False))


# ---- arxiv-sync ---------------------------------------------------------------------------------

arxiv_sync = script_load("arxiv-sync")

ARXIV_RSS = """<?xml version="1.0"?>
<rss xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom" version="2.0"><channel>
<item><title>$L^p$ bounds for $p&lt;q$ and \\mathbb{R}</title><link>https://arxiv.org/abs/2610.00002</link>
<category>math.AP</category><arxiv:announce_type>new</arxiv:announce_type><pubDate>Tue, 06 Oct 2026 00:00:00 -0400</pubDate>
<dc:creator>A. M\\"uller (Univ. Bonn, Germany), B. &lt;b&gt;Bold&lt;/b&gt;</dc:creator></item>
<item><title>Cross-listed</title><link>https://arxiv.org/abs/2610.00003</link><category>cs.LG</category>
<arxiv:announce_type>cross</arxiv:announce_type><pubDate>Tue, 06 Oct 2026 00:00:00 -0400</pubDate>
<dc:creator>C. Cross</dc:creator></item>
<item><title>Yesterday</title><link>https://arxiv.org/abs/2610.00001</link><category>math.NT</category>
<arxiv:announce_type>new</arxiv:announce_type><pubDate>Mon, 05 Oct 2026 00:00:00 -0400</pubDate>
<dc:creator>D. Old</dc:creator></item>
</channel></rss>"""


class ArxivSync(unittest.TestCase):
    def test_payload_keeps_the_newest_day_of_new_papers(self):
        channel = arxiv_sync.ET.fromstring(ARXIV_RSS).find("channel")
        payload = arxiv_sync.payload_build(channel, datetime.datetime(2026, 10, 6, 8, 0, tzinfo=BERLIN))
        self.assertEqual(payload["total"], 1)
        paper = payload["papers"][0]
        self.assertEqual(paper["title"], "L^p bounds for p<q and R")
        self.assertEqual(paper["authors"], "Muller, <b>Bold</b>")
        self.assertEqual(payload["subjects"], [{"name": "Analysis of PDEs", "count": 1}])
        payload_write("arxiv", payload)

    def test_dates(self):
        self.assertIsNone(arxiv_sync.parse_date("not a date"))
        self.assertIsNotNone(arxiv_sync.parse_date("Tue, 06 Oct 2026 00:00:00 GMT").utcoffset())


# ---- trmnl-sync ---------------------------------------------------------------------------------

trmnl_sync = script_load("trmnl-sync")


class TrmnlSync(unittest.TestCase):
    def test_pushes_only_what_changed_and_spaces_the_pushes(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = os.path.join(tmp, "key")
            with open(key, "w") as handle:
                handle.write("secret\n")
            templates = {}
            for name in ("same", "new", "other"):
                templates[name] = os.path.join(tmp, f"{name}.liquid")
                with open(templates[name], "w") as handle:
                    handle.write(f"<p>{name}</p>")
            have = {"/1/markup/markup_full": "<p>same</p>", "/2/markup/markup_full": "<p>old</p>",
                    "/3/markup/markup_full": "<p>old</p>"}
            pushed, slept = [], []

            def call(path, token, body=None, method=None):
                self.assertEqual(token, "secret")
                if path == "/4/markup/markup_full":
                    raise urllib.error.URLError("unreachable")
                if method == "PUT":
                    pushed.append((path, body["content"]))
                    return None
                return {"data": {"markup": have[path]}}

            saved = (trmnl_sync.call, trmnl_sync.time.sleep, sys.argv)
            os.environ["TRMNL_API_KEY_FILE"] = key
            try:
                trmnl_sync.call, trmnl_sync.time.sleep = call, slept.append
                sys.argv = ["trmnl-sync", f"1={templates['same']}", f"2={templates['new']}", f"3={templates['other']}",
                            f"4={templates['other']}"]
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    rc = trmnl_sync.main()
            finally:
                trmnl_sync.call, trmnl_sync.time.sleep, sys.argv = saved
        self.assertEqual(rc, 1)
        self.assertEqual(pushed, [("/2/markup/markup_full", "<p>new</p>"), ("/3/markup/markup_full", "<p>other</p>")])
        self.assertEqual(slept, [trmnl_sync.PUSH_INTERVAL_S])


if __name__ == "__main__":
    unittest.main()
