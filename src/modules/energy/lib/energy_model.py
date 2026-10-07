"""The house's energy model, defined once: series, cost formula, local days and day-ahead prices.

Consumers:
- instances/105-internal-grafana/lib/dashboards/energy.py builds the Grafana board "Energie" from these queries over $__range.
- instances/104-internal-terminal/lib/energy-sync.py evaluates the same queries per window for the TRMNL panel, and exports local-day and
  local-month totals as node-exporter gauges that the board's per-day and per-month bars read.
- instances/105-internal-grafana/lib/spot-price.py exports the running quarter hour's day-ahead price from the shared price cache.

Overview:
    INPUTS                                   the hand-typed inputs, lib/inputs.nix as json
    Window, window_from_seconds(s, at_s)     a query window: its length and, optionally, the instant it ends
    energy_kwh(power, window)                a power series summed per minute, in kWh
    meter_rise(metric, window)               rise of a monotonic reading, robust to a corrected typo
    meter_kwh(metric_wh, window)             meter_rise of a watt-hour counter, in kWh
    tariff(key, window)                      a tariff helper as a label-free vector, absent while unset
    cost_terms(window, fee_seconds)          every cost term in EUR, the one formula of the board and the panel
    cost_net(terms)                          what the household pays over the window
    cost_savings(terms)                      what pv and battery earned over the window
    cost_forecast(terms, horizon_s)          the last COVERAGE_S extrapolated
    import_at_spot_eur(window)               the grid import at the day-ahead price
    energy_terms(window)                     energy flows in kWh and meter rises in cubic meters
    PERIOD_TERMS, period_metric(period, unit)  energy-sync's per-day and per-month gauges
    covered_seconds()                        seconds of the last COVERAGE_S that have meter data
    query_batch(terms)                       many label-free terms in one query, told apart by a `term` label
    local_day_bounds(day), local_month_bounds(year, month)   [start, end) in unix seconds, dst-correct
    spot_fetch(urlopen, api, zone, first_day, last_day)      energy-charts day-ahead prices
    spot_cache_fetch_due(cache, now_s)       whether the price cache misses a published day, retried hourly
    spot_cache_refresh(cache, now_s, fetch_slots), spot_cache_slots(cache)
    spot_current(slots, now_s), spot_day_stats(slots, start_s, end_s)
    spot_hourly(slots, from_s, hours_max), spot_cheapest_window(hourly, hours)

Example:
    day_start_s, day_end_s = local_day_bounds(datetime.date(2026, 3, 29))
    window = window_from_seconds(day_end_s - day_start_s, at_s=day_end_s)
    query = query_batch(cost_terms(window))      # one round trip, one sample per term

Missing data: a term whose inputs are missing is missing too, and so is the net cost; the panel prints "-", the
board "no value". Rejected alternative: `or vector(0)` counted an unread meter as free and an unset price as
0 EUR, so both showed a cheap month that was really unknown, and their copies of the formula drifted apart.

Local days: a window is built from local midnights with zoneinfo, never by adding 24 h to an aware datetime.
A fixed-offset datetime plus timedelta(days=1) is exactly 86400 s, so on 2026-03-29 (23 h) and 2026-10-25 (25 h)
the old windows were an hour off.
"""
import dataclasses
import datetime
import json
import pathlib
import urllib.error
import urllib.parse
from zoneinfo import ZoneInfo

# ---- constants ----------------------------------------------------------------------------------

INPUTS = json.loads((pathlib.Path(__file__).parent / "energy_inputs.json").read_text())
# local days, the spot price's "today" and the reading clock all follow the house's zone
HOUSE_ZONE = ZoneInfo(INPUTS["timeZone"])

SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
SECONDS_PER_DAY = 86400
MINUTES_PER_HOUR = 60
WATTS_PER_KILOWATT = 1000
WATT_HOURS_PER_KILOWATT_HOUR = 1000
# a calendar month on average (365.25 / 12 days): base fees are per month, prorated by the second
SECONDS_PER_MONTH = 30.4375 * SECONDS_PER_DAY
SECONDS_PER_YEAR = 365.25 * SECONDS_PER_DAY
# the forecast extrapolates the last 30 days; a younger history extrapolates what it has
COVERAGE_S = 30 * SECONDS_PER_DAY
# a forecast from less than an hour of data is noise
COVERAGE_MIN_S = SECONDS_PER_HOUR
# the subquery step of covered_seconds stays within prometheus' 5 m lookback, or the first samples fall between
COVERAGE_STEP = "5m"

# the fronius exporter (instances/105-internal-grafana/lib/fronius-exporter.py); signs: load and pv positive, grid positive importing,
# battery positive discharging
PV_W = "fronius_pv_watts"
LOAD_W = "fronius_load_watts"
GRID_W = "fronius_grid_watts"
BATTERY_W = "fronius_battery_watts"
UNACCOUNTED_W = "fronius_unaccounted_watts"
SOC_RATIO = "fronius_battery_soc_ratio"
IMPORT_WH = "fronius_meter_import_wh"
EXPORT_WH = "fronius_meter_export_wh"
IMPORT_W = f"clamp_min({GRID_W}, 0)"
EXPORT_W = f"clamp_min(-{GRID_W}, 0)"
DISCHARGE_W = f"clamp_min({BATTERY_W}, 0)"
CHARGE_W = f"clamp_min(-{BATTERY_W}, 0)"
# load drawn from pv and battery; `and` keeps it to the minutes the load is known, so an hidden generator's
# minutes (fronius_unaccounted_watts) bias neither side
SELF_W = f"clamp_min({LOAD_W} - {IMPORT_W}, 0)"
IMPORT_KNOWN_LOAD_W = f"({IMPORT_W} and {LOAD_W})"
EXPORT_KNOWN_PV_W = f"({EXPORT_W} and {PV_W})"

METERS = INPUTS["meters"]
GAS_M3 = METERS["gas"]["readingMetric"]
WATER_M3 = METERS["water"]["readingMetric"]
TARIFFS = tuple(sorted(INPUTS["tariffs"]))
# readings are typed daily: a day and a half late is a missed day, three days a forgotten meter
READING_STALE_S = 36 * SECONDS_PER_HOUR
READING_OVERDUE_S = 72 * SECONDS_PER_HOUR

# energy-sync's totals per local day and month, as node-exporter gauges on vm-104: term -> (unit, label, value);
# homelab_energy_<period>_<unit>{<period>="2026-10-05", <label>="<value>"}
PERIOD_LABEL_FORMATS = {"day": "%Y-%m-%d", "month": "%Y-%m"}
# how many complete periods are exported besides the running one: the board's bars and the panel's history
PERIOD_COUNTS = {"day": 30, "month": 12}
PERIOD_TERMS = {
    "pv_kwh": ("kwh", "flow", "pv"),
    "load_kwh": ("kwh", "flow", "load"),
    "import_kwh": ("kwh", "flow", "import"),
    "export_kwh": ("kwh", "flow", "export"),
    "gas_m3": ("m3", "meter", "gas"),
    "water_m3": ("m3", "meter", "water"),
    "electricity_eur": ("eur", "part", "electricity"),
    "gas_eur": ("eur", "part", "gas"),
    "water_eur": ("eur", "part", "water"),
    "base_fees_eur": ("eur", "part", "base_fees"),
    "feed_in_eur": ("eur", "part", "feed_in"),
}

SPOT_ZONE = "DE-LU"
SPOT_API = "https://api.energy-charts.info/price"
SPOT_SERIES = f'energy_spot_price_eur_per_kwh{{zone="{SPOT_ZONE}"}}'
EUR_PER_MWH_TO_EUR_PER_KWH = 1 / 1000
# epex publishes the next day's auction at about 12:45 CET, energy-charts some minutes later
SPOT_PUBLISHED_HOUR_LOCAL = 13
# a late publication is retried hourly, not every run
SPOT_RETRY_S = SECONDS_PER_HOUR
# the longest slot energy-charts serves: hourly until 2025-10-01, quarter hours since
SPOT_SLOT_MAX_S = SECONDS_PER_HOUR
SPOT_TIMEOUT_S = 20


# ---- windows ------------------------------------------------------------------------------------

@dataclasses.dataclass(frozen=True)
class Window:
    """A query window: `duration` for range selectors, `seconds` as a number literal, ending at `at_s` or now."""

    duration: str
    seconds: str
    at_s: int | None = None

    def modifier(self):
        return f" @ {self.at_s}" if self.at_s is not None else ""


def window_from_seconds(seconds, at_s=None):
    assert seconds > 0, seconds
    return Window(f"{int(seconds)}s", str(int(seconds)), None if at_s is None else int(at_s))


# grafana's macros: the picked range, in both forms
WINDOW_RANGE = Window("$__range", "$__range_s")


# ---- queries ------------------------------------------------------------------------------------

def energy_kwh(power_w, window):
    """One-minute samples summed: a scrape gap counts as nothing, the same as on the meter.

    Averaging times the window would fill gaps with the mean and disagree with the meter after every outage.
    """
    return (f"sum(sum_over_time(({power_w})[{window.duration}:1m]{window.modifier()}))"
            f" / {MINUTES_PER_HOUR} / {WATTS_PER_KILOWATT}")


def meter_rise(metric, window):
    """Rise of a monotonic reading over the window: the last value minus the window's minimum.

    A too-high entry corrected later is above the corrected value, so it is never the minimum and never counts;
    max minus min counted it until it left the window. Rejected alternative: increase() treats a correction as a
    meter reset and counts the whole reading again.
    """
    selector = f"{metric}[{window.duration}]{window.modifier()}"
    return f"sum(clamp_min(last_over_time({selector}) - min_over_time({selector}), 0))"


def meter_kwh(metric_wh, window):
    return f"{meter_rise(metric_wh, window)} / {WATT_HOURS_PER_KILOWATT_HOUR}"


def tariff_selector(key):
    """A tariff helper's series; the integration mangles the unit into the name, so match the prefix."""
    assert key in INPUTS["tariffs"], key
    return f'{{__name__=~"{INPUTS["helperMetricPrefix"]}.*", entity="input_number.{key}"}}'


def tariff(key, window=None):
    """A tariff as a label-free vector; an input_number starts at its min, 0, so 0 is unset and absent."""
    modifier = window.modifier() if window is not None else ""
    return f"max({tariff_selector(key)}{modifier} > 0)"


def cost_terms(window, fee_seconds=None):
    """Every cost term over the window in EUR, label-free vectors keyed by name.

    fee_seconds (a number literal or a label-free vector expression) prorates the monthly base fees; it defaults to
    the window, the forecast passes the seconds it has data for.
    """
    fees = " + ".join(tariff(key, window) for key in ("fee_electricity", "fee_gas", "fee_water"))
    return {
        "electricity_eur": f"({meter_kwh(IMPORT_WH, window)}) * {tariff('price_electricity', window)}",
        "gas_eur": f"({meter_rise(GAS_M3, window)}) * {tariff('gas_kwh_per_m3', window)}"
                   f" * {tariff('price_gas', window)}",
        "water_eur": f"({meter_rise(WATER_M3, window)}) * {tariff('price_water', window)}",
        "base_fees_eur": f"({fees}) * {fee_seconds or window.seconds} / {SECONDS_PER_MONTH}",
        "feed_in_eur": f"({meter_kwh(EXPORT_WH, window)}) * {tariff('price_feed_in', window)}",
        "pv_savings_eur": f"({energy_kwh(SELF_W, window)}) * {tariff('price_electricity', window)}",
    }


def import_at_spot_eur(window):
    """The window's grid import priced at the day-ahead price, without fees: a dynamic tariff's wholesale share.

    on() group_left(): a minute without a spot price drops out instead of turning the sum NaN.
    """
    return energy_kwh(f"{IMPORT_W} * on() group_left() {SPOT_SERIES}", window)


def cost_net(terms):
    """Paid over the window: import, gas, water and base fees, less the feed-in tariff."""
    return (f"({terms['electricity_eur']}) + ({terms['gas_eur']}) + ({terms['water_eur']})"
            f" + ({terms['base_fees_eur']}) - ({terms['feed_in_eur']})")


def cost_savings(terms):
    """What pv and battery earned over the window: the import they replaced plus the feed-in tariff."""
    return f"({terms['pv_savings_eur']}) + ({terms['feed_in_eur']})"


def cost_forecast(terms, horizon_s):
    """The net cost of `terms` (a COVERAGE_S window, fees over covered_seconds) extrapolated to horizon_s."""
    return f"({cost_net(terms)}) * {horizon_s} / {covered_seconds()}"


def period_metric(period, unit):
    assert period in PERIOD_LABEL_FORMATS, period
    return f"homelab_energy_{period}_{unit}"


def covered_seconds():
    """Seconds of the last COVERAGE_S with grid meter data, at least COVERAGE_MIN_S, as a label-free vector."""
    first = f"min_over_time(timestamp({IMPORT_WH})[{COVERAGE_S}s:{COVERAGE_STEP}])"
    return f"(max(clamp_max(time() - {first}, {COVERAGE_S})) > {COVERAGE_MIN_S})"


def energy_terms(window):
    """Energy over the window in kWh and cubic meters, label-free vectors keyed by name."""
    return {
        "pv_kwh": energy_kwh(PV_W, window),
        "load_kwh": energy_kwh(LOAD_W, window),
        "self_kwh": energy_kwh(SELF_W, window),
        "import_kwh": meter_kwh(IMPORT_WH, window),
        "export_kwh": meter_kwh(EXPORT_WH, window),
        "charge_kwh": energy_kwh(CHARGE_W, window),
        "discharge_kwh": energy_kwh(DISCHARGE_W, window),
        # ratio inputs, over the minutes both sides are known
        "import_known_load_kwh": energy_kwh(IMPORT_KNOWN_LOAD_W, window),
        "export_known_pv_kwh": energy_kwh(EXPORT_KNOWN_PV_W, window),
        "gas_m3": meter_rise(GAS_M3, window),
        "water_m3": meter_rise(WATER_M3, window),
    }


def query_batch(terms):
    """Label-free terms as one query; each result carries its name in the `term` label."""
    assert terms, "an empty batch is not a query"
    return " or ".join(f'label_replace(({expr}), "term", "{name}", "", "")' for name, expr in terms.items())


def query_batch_parse(result):
    """A batch query's instant vector ({"metric", "value"} rows) as term -> float; missing terms are absent."""
    out = {}
    for row in result:
        name = row.get("metric", {}).get("term")
        try:
            out[name] = float(row["value"][1])
        except (KeyError, IndexError, TypeError, ValueError):
            continue
    return out


# ---- local time ---------------------------------------------------------------------------------

def local_midnight(day, zone=HOUSE_ZONE):
    """00:00 of a local calendar day as an aware datetime with that day's own offset."""
    return datetime.datetime.combine(day, datetime.time(0), zone)


def local_day_bounds(day, zone=HOUSE_ZONE):
    """[start, end) of a local day in unix seconds: 23 h, 24 h or 25 h long."""
    start = local_midnight(day, zone).timestamp()
    end = local_midnight(day + datetime.timedelta(days=1), zone).timestamp()
    assert end > start, (day, start, end)
    return int(start), int(end)


def local_month_bounds(year, month, zone=HOUSE_ZONE):
    assert 1 <= month <= 12, month
    first = datetime.date(year, month, 1)
    following = datetime.date(year + month // 12, month % 12 + 1, 1)
    return int(local_midnight(first, zone).timestamp()), int(local_midnight(following, zone).timestamp())


def local_today(now_s, zone=HOUSE_ZONE):
    return datetime.datetime.fromtimestamp(now_s, zone).date()


# ---- day-ahead prices ---------------------------------------------------------------------------

def spot_parse(body):
    """An energy-charts answer as sorted (unix_seconds, eur_per_kwh) pairs, or None if malformed."""
    if not isinstance(body, dict):
        return None
    times, prices = body.get("unix_seconds") or [], body.get("price") or []
    if len(times) != len(prices):
        return None
    slots = []
    for t, p in zip(times, prices):
        if isinstance(t, (int, float)) and isinstance(p, (int, float)) and not isinstance(p, bool):
            slots.append((int(t), p * EUR_PER_MWH_TO_EUR_PER_KWH))
    return sorted(slots)


def spot_fetch(urlopen, api, zone, first_day, last_day):
    """Day-ahead slots for [first_day, last_day] (local dates), or None; urlopen is injected for tests."""
    query = urllib.parse.urlencode({"bzn": zone, "start": first_day.isoformat(), "end": last_day.isoformat()})
    try:
        with urlopen(f"{api}?{query}", timeout=SPOT_TIMEOUT_S) as response:
            body = json.load(response)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        return None
    return spot_parse(body)


def spot_cache_fetch_due(cache, now_s, zone=HOUSE_ZONE):
    """Whether the price cache {"attempted_at_s", "slots"} misses a day that is, or should be, published.

    Today's prices must run to the end of today; tomorrow's are due once epex has published them. Any attempt,
    good or failed, waits SPOT_RETRY_S before the next, so an outage or a late publication costs one call an hour.
    """
    if cache and now_s - cache.get("attempted_at_s", 0) < SPOT_RETRY_S:
        return False
    slots = (cache or {}).get("slots") or []
    if not slots:
        return True
    today = local_today(now_s, zone)
    _, today_end_s = local_day_bounds(today, zone)
    _, tomorrow_end_s = local_day_bounds(today + datetime.timedelta(days=1), zone)
    last_slot_s = max(t for t, _ in slots)
    if last_slot_s < today_end_s - SPOT_SLOT_MAX_S:
        return True
    published = datetime.datetime.fromtimestamp(now_s, zone).hour >= SPOT_PUBLISHED_HOUR_LOCAL
    return published and last_slot_s < tomorrow_end_s - SPOT_SLOT_MAX_S


def spot_cache_refresh(cache, now_s, fetch_slots, zone=HOUSE_ZONE):
    """The cache after a fetch of today and tomorrow, if one is due; fetch_slots(first_day, last_day) -> slots or None.

    A failed or empty fetch keeps the cached slots and still counts as an attempt.
    """
    if not spot_cache_fetch_due(cache, now_s, zone):
        return cache
    today = local_today(now_s, zone)
    slots = fetch_slots(today, today + datetime.timedelta(days=1))
    kept = [tuple(slot) for slot in (cache or {}).get("slots") or []]
    return {"attempted_at_s": now_s, "slots": [list(slot) for slot in (slots or kept)]}


def spot_cache_slots(cache):
    """The cache's slots as sorted (unix_seconds, eur_per_kwh) tuples."""
    return sorted(tuple(slot) for slot in (cache or {}).get("slots") or [])


def spot_current(slots, now_s):
    """Price of the slot running at now_s, or None.

    A slot runs until the next one starts, at most SPOT_SLOT_MAX_S across a gap; the last one lasts as long as
    the one before it (the data's own resolution, hourly or quarter-hourly), a lone slot SPOT_SLOT_MAX_S.
    """
    starts = [t for t, _ in slots]
    started = [i for i, t in enumerate(starts) if t <= now_s]
    if not started:
        return None
    i = started[-1]
    if i + 1 < len(slots):
        return slots[i][1] if now_s - starts[i] < SPOT_SLOT_MAX_S else None
    length_s = starts[i] - starts[i - 1] if i > 0 else SPOT_SLOT_MAX_S
    return slots[i][1] if now_s < starts[i] + length_s else None


def spot_day_stats(slots, start_s, end_s):
    """(min, mean, max) of the slots starting in [start_s, end_s), or None."""
    day = [p for t, p in slots if start_s <= t < end_s]
    if not day:
        return None
    return min(day), sum(day) / len(day), max(day)


def spot_hourly(slots, from_s, hours_max):
    """Hourly means from the hour running at from_s on, at most hours_max hours."""
    hours = {}
    for t, p in slots:
        if t // SECONDS_PER_HOUR >= from_s // SECONDS_PER_HOUR:
            hours.setdefault(t // SECONDS_PER_HOUR, []).append(p)
    hourly = [(h * SECONDS_PER_HOUR, sum(ps) / len(ps)) for h, ps in sorted(hours.items())]
    return hourly[:hours_max]


def spot_cheapest_window(hourly, hours):
    """The consecutive run of `hours` hours with the lowest mean, as (start_s, mean), or None."""
    assert hours >= 1, hours
    best = None
    for i in range(len(hourly) - hours + 1):
        run = hourly[i:i + hours]
        # a gap (a missing hour) is not a consecutive run
        if run[-1][0] - run[0][0] != (hours - 1) * SECONDS_PER_HOUR:
            continue
        mean = sum(p for _, p in run) / hours
        if best is None or mean < best[1]:
            best = (run[0][0], mean)
    return best
