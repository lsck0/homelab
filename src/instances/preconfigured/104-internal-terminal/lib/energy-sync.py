"""Build the TRMNL energy panel and export local-day and local-month energy totals.

Usage: energy-sync.py <feed-dir> <state-dir>
Env:   ENERGY_PROMETHEUS (prometheus base url), ENERGY_SPOT_API (optional, the energy-charts price api)

Every query comes from energy_model (modules/energy), the definitions the Grafana board "Energie" uses too, so
the panel and the board cannot disagree. Writes:
- <feed-dir>/energy.json: the panel's payload (lib/trmnl/energy.liquid); German labels, it is read at home.
- <state-dir>/energy.prom: node-exporter gauges homelab_energy_{day,month}_{kwh,eur,m3}, the totals of the last
  local days and months, which the board's bars read; 104-internal-terminal/main.nix installs it as a textfile.
- <state-dir>/days.json: the totals of completed local days. A completed day never changes, so each is queried
  once and a month is the sum of its days; missing days are backfilled, newest first, DAYS_BACKFILL_MAX per run.
- <state-dir>/spot.json: the day-ahead price cache, fetched only when a published day is missing.

A Prometheus that does not answer leaves "-" everywhere, never a 0, and says so in the footer.
"""
import datetime
import os
import sys
import time
import urllib.request

import energy_model as em
import feed_io

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

# the panel's chart viewbox (energy.liquid), the template scales it to its box
CHART_WIDTH_PX = 480
CHART_HEIGHT_PX = 120
# 288 points a day, fine at 480 px
CHART_STEP_S = 300
# the chart's axis rounds the day's peak up to whole kilowatts, at least one
CHART_AXIS_STEP_W = 1000
# the panel's bar strip
HISTORY_DAYS = 14
# the cheapest block worth planning a wash or a charge around
CHEAP_WINDOW_HOURS = 3
SPOT_HOURS_SHOWN = 24
# cheap bars are the short ones and must stay visible
SPOT_BAR_FLOOR_PERCENT = 25
SPOT_HOUR_LABEL_EVERY = 6
CENTS_PER_EURO = 100
PERCENT = 100
MONTHS_PER_YEAR = 12
DAYS_PER_WEEK = 7
# "YYYY-MM" of a day's "YYYY-MM-DD" key
MONTH_KEY_CHARS = 7
# the inverter's own reading jitters a few watts around zero at rest
BATTERY_IDLE_W = 5
# the last scrape of a day is in a few minutes after its end
PERIOD_SETTLE_S = 300
# a fresh state fills the visible month in one run and the year within the hour
DAYS_BACKFILL_MAX = 31
WEEKDAYS = ("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")
MISSING = "-"

PROMETHEUS = os.environ.get("ENERGY_PROMETHEUS", "")
SPOT_API = os.environ.get("ENERGY_SPOT_API", em.SPOT_API)


# -----------------------------------------------------------------------------
# FORMATTING
# -----------------------------------------------------------------------------

def format_decimal(value, digits=1):
    """German decimal with thousands dots, "-" when unknown."""
    if value is None:
        return MISSING
    text = f"{value:,.{digits}f}"
    return text.replace(",", "_").replace(".", ",").replace("_", ".")


def format_power(watts):
    if watts is None:
        return MISSING
    return f"{format_decimal(watts / em.WATTS_PER_KILOWATT, 2)} kW" if abs(watts) >= em.WATTS_PER_KILOWATT \
        else f"{watts:.0f} W"


def format_age(seconds):
    if seconds is None:
        return "nie"
    if seconds < em.SECONDS_PER_HOUR:
        return f"vor {seconds // em.SECONDS_PER_MINUTE:.0f} min"
    if seconds < em.SECONDS_PER_DAY:
        return f"vor {seconds // em.SECONDS_PER_HOUR:.0f} h"
    return f"vor {seconds // em.SECONDS_PER_DAY:.0f} d"


def format_percent(fraction):
    return f"{max(0.0, min(1.0, fraction)) * PERCENT:.0f} %" if fraction is not None else MISSING


def chart_path(points, t0, t1, value_max, close):
    """SVG path over [t0, t1] x [0, value_max] in the chart viewbox; closed paths are filled areas."""
    assert t1 > t0, (t0, t1)
    if not points or value_max <= 0:
        return ""
    xy = [((t - t0) / (t1 - t0) * CHART_WIDTH_PX,
           CHART_HEIGHT_PX - max(0.0, min(v, value_max)) / value_max * CHART_HEIGHT_PX) for t, v in points]
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in xy)
    if close:
        d += f" L{xy[-1][0]:.1f},{CHART_HEIGHT_PX} L{xy[0][0]:.1f},{CHART_HEIGHT_PX} Z"
    return d


def ratio_from(numerator, denominator):
    """1 - numerator / denominator, the share not drawn from it; None when either is unknown or zero."""
    if numerator is None or not denominator:
        return None
    return 1 - numerator / denominator


# -----------------------------------------------------------------------------
# QUERIES
# -----------------------------------------------------------------------------

class Source:
    """Prometheus at one instant: batched queries, None when it did not answer."""

    def __init__(self, base, now_s, urlopen):
        self.base, self.now_s, self.urlopen = base, now_s, urlopen
        self.failed = False

    def terms(self, terms):
        rows = feed_io.prometheus_query(self.base, em.query_batch(terms), self.now_s, self.urlopen)
        if rows is None:
            self.failed = True
            return None
        return em.query_batch_parse(rows)

    def ranges(self, terms, start_s, end_s, step_s):
        rows = feed_io.prometheus_query_range(self.base, em.query_batch(terms), start_s, end_s, step_s, self.urlopen)
        if rows is None:
            self.failed = True
            return {}
        out = {}
        for row in rows:
            try:
                out[row["metric"]["term"]] = [(float(t), float(v)) for t, v in row["values"]]
            except (KeyError, TypeError, ValueError):
                continue
        return out


def period_terms(window):
    """Every PERIOD_TERMS term over one window."""
    terms = em.energy_terms(window) | em.cost_terms(window)
    return {name: terms[name] for name in em.PERIOD_TERMS}


# -----------------------------------------------------------------------------
# PERIODS
# -----------------------------------------------------------------------------

def days_kept_from(today):
    """The first day the month bars need: the first of the month PERIOD_COUNTS["month"] months back."""
    months_back = em.PERIOD_COUNTS["month"]
    month_index = today.year * MONTHS_PER_YEAR + today.month - 1 - months_back
    return datetime.date(month_index // MONTHS_PER_YEAR, month_index % MONTHS_PER_YEAR + 1, 1)


def days_due(days, today, now_s):
    """Complete days the cache lacks, newest first, at most DAYS_BACKFILL_MAX."""
    due = []
    day = today - datetime.timedelta(days=1)
    first = days_kept_from(today)
    while day >= first and len(due) < DAYS_BACKFILL_MAX:
        _, end_s = em.local_day_bounds(day)
        if day.isoformat() not in days and end_s + PERIOD_SETTLE_S <= now_s:
            due.append(day)
        day -= datetime.timedelta(days=1)
    return due


def days_update(days, source, today, now_s):
    """The cache with every due day queried; a day prometheus failed on stays due."""
    first = days_kept_from(today).isoformat()
    kept = {key: value for key, value in days.items() if key >= first}
    for day in days_due(kept, today, now_s):
        start_s, end_s = em.local_day_bounds(day)
        values = source.terms(period_terms(em.window_from_seconds(end_s - start_s, at_s=end_s)))
        if values is not None:
            kept[day.isoformat()] = values
    return kept


def months_from_days(days):
    """month label -> term -> the sum over its days that have the term."""
    months = {}
    for key, values in days.items():
        month = months.setdefault(key[:MONTH_KEY_CHARS], {})
        for term, value in values.items():
            month[term] = month.get(term, 0.0) + value
    return months


def textfile_render(day_totals, month_totals):
    """node-exporter gauges of the shown days and months, one series per period and term."""
    lines = []
    for period, totals in (("day", day_totals), ("month", month_totals)):
        by_metric = {}
        for label_value, values in sorted(totals.items()):
            for term, value in sorted(values.items()):
                unit, label, kind = em.PERIOD_TERMS[term]
                by_metric.setdefault(em.period_metric(period, unit), []).append(
                    f'{em.period_metric(period, unit)}{{{period}="{label_value}",{label}="{kind}"}} {value!r}')
        for metric, samples in sorted(by_metric.items()):
            lines.append(f"# HELP {metric} Energy totals per local {period}, from energy-sync.py.")
            lines.append(f"# TYPE {metric} gauge")
            lines.extend(samples)
    return "\n".join(lines) + "\n"


def periods_shown(days, today_values, today):
    """The last PERIOD_COUNTS days and months, today and this month included as far as they are known."""
    all_days = dict(days)
    if today_values:
        all_days[today.isoformat()] = today_values
    day_keys = sorted(all_days)[-(em.PERIOD_COUNTS["day"] + 1):]
    months = months_from_days(all_days)
    month_keys = sorted(months)[-(em.PERIOD_COUNTS["month"] + 1):]
    return {k: all_days[k] for k in day_keys}, {k: months[k] for k in month_keys}


# -----------------------------------------------------------------------------
# PANEL SECTIONS
# -----------------------------------------------------------------------------

def section_now(source):
    values = source.terms({
        "pv": f"max({em.PV_W})", "load": f"max({em.LOAD_W})", "grid": f"max({em.GRID_W})",
        "battery": f"max({em.BATTERY_W})", "soc": f"max({em.SOC_RATIO})", "unaccounted": f"max({em.UNACCOUNTED_W})",
        "online": "min(fronius_up)",
    })
    if values is None:
        values = {}
    grid, battery, soc = values.get("grid"), values.get("battery"), values.get("soc")
    battery_label = "ruht"
    if battery is not None and battery > BATTERY_IDLE_W:
        battery_label = "entlädt"
    elif battery is not None and battery < -BATTERY_IDLE_W:
        battery_label = "lädt"
    return {
        "pv": format_power(values.get("pv")),
        "load": format_power(values.get("load")),
        "unaccounted": format_power(values.get("unaccounted")) if values.get("unaccounted") is not None else "",
        "grid": format_power(abs(grid)) if grid is not None else MISSING,
        "grid_label": "Einspeisung" if grid is not None and grid < 0 else "Netzbezug",
        "battery": format_power(abs(battery)) if battery is not None else MISSING,
        "battery_label": battery_label if battery is not None else MISSING,
        "soc": f"{soc * PERCENT:.0f} %" if soc is not None else MISSING,
        "soc_pct": round(soc * PERCENT) if soc is not None else 0,
        "online": values.get("online") == 1,
    }


def section_chart(source, midnight_s, next_midnight_s, now_s):
    series = source.ranges({"pv": f"max({em.PV_W})", "load": f"max({em.LOAD_W})", "soc": f"max({em.SOC_RATIO})"},
                           midnight_s, now_s, CHART_STEP_S)
    pv, load, soc = series.get("pv", []), series.get("load", []), series.get("soc", [])
    peak = max([v for _, v in pv + load] + [CHART_AXIS_STEP_W])
    top = -(-peak // CHART_AXIS_STEP_W) * CHART_AXIS_STEP_W
    return {
        "pv": chart_path(pv, midnight_s, next_midnight_s, top, close=True),
        "load": chart_path(load, midnight_s, next_midnight_s, top, close=False),
        "soc": chart_path(soc, midnight_s, next_midnight_s, 1.0, close=False),
        "top": f"{top / em.WATTS_PER_KILOWATT:.0f} kW",
        "now_x": round((now_s - midnight_s) / (next_midnight_s - midnight_s) * CHART_WIDTH_PX, 1),
    }


def section_today(values):
    values = values or {}
    return {
        "pv": format_decimal(values.get("pv_kwh")), "load": format_decimal(values.get("load_kwh")),
        "import": format_decimal(values.get("import_kwh")), "export": format_decimal(values.get("export_kwh")),
        "autarky": format_percent(ratio_from(values.get("import_known_load_kwh"), values.get("load_kwh"))),
        "self_use": format_percent(ratio_from(values.get("export_known_pv_kwh"), values.get("pv_kwh"))),
        "cost": format_decimal(values.get("net_eur"), 2), "saved": format_decimal(values.get("savings_eur"), 2),
    }


def today_terms(midnight_s, now_s):
    """Today so far: energy, every cost term, the net cost and the savings, as one batch."""
    window = em.window_from_seconds(max(now_s - midnight_s, em.SECONDS_PER_MINUTE), at_s=now_s)
    costs = em.cost_terms(window)
    return em.energy_terms(window) | costs | {"net_eur": em.cost_net(costs), "savings_eur": em.cost_savings(costs)}


def section_forecast(source):
    last30 = em.cost_terms(em.window_from_seconds(em.COVERAGE_S), fee_seconds=em.covered_seconds())
    values = source.terms({"month": em.cost_forecast(last30, em.SECONDS_PER_MONTH),
                           "year": em.cost_forecast(last30, em.SECONDS_PER_YEAR),
                           "covered_s": em.covered_seconds()}) or {}
    covered_s = values.get("covered_s")
    return {"month": format_decimal(values.get("month"), 0), "year": format_decimal(values.get("year"), 0),
            "days": round(covered_s / em.SECONDS_PER_DAY) if covered_s is not None else 0}


def section_history(days, today):
    """The last HISTORY_DAYS complete days, oldest first, bars scaled to the busiest one."""
    rows = []
    for back in range(HISTORY_DAYS, 0, -1):
        day = today - datetime.timedelta(days=back)
        values = days.get(day.isoformat(), {})
        rows.append({"label": WEEKDAYS[day.weekday()], "date": day.strftime("%d."),
                     "pv": values.get("pv_kwh"), "load": values.get("load_kwh")})
    top = max([r[k] or 0 for r in rows for k in ("pv", "load")] + [1])
    for r in rows:
        r["pv_pct"] = round((r["pv"] or 0) / top * PERCENT)
        r["load_pct"] = round((r["load"] or 0) / top * PERCENT)
        r["pv"], r["load"] = format_decimal(r["pv"]), format_decimal(r["load"])
    return {"days": rows, "top": format_decimal(top, 0)}


def inputs_terms(now_s):
    """Readings, their age and last week, and every tariff, as one batch."""
    week = em.window_from_seconds(DAYS_PER_WEEK * em.SECONDS_PER_DAY, at_s=now_s)
    week_costs = em.cost_terms(week)
    terms = {f"tariff_{key}": em.tariff(key) for key in em.TARIFFS}
    for meter, m in em.METERS.items():
        terms[f"{meter}_reading"] = f"max({m['readingMetric']})"
        terms[f"{meter}_read_at"] = f"max({m['readAtMetric']})"
        terms[f"{meter}_week"] = em.meter_rise(m["readingMetric"], week)
        terms[f"{meter}_week_eur"] = week_costs[f"{meter}_eur"]
    return terms


def section_meter(values, meter, now_s):
    read_at_s = values.get(f"{meter}_read_at")
    age_s = now_s - read_at_s if read_at_s is not None else None
    return {
        "reading": format_decimal(values.get(f"{meter}_reading"), 3),
        "age": format_age(age_s),
        "stale": age_s is None or age_s > em.READING_STALE_S,
        "week": format_decimal(values.get(f"{meter}_week"), 2),
        "week_cost": format_decimal(values.get(f"{meter}_week_eur"), 2),
    }


def section_spot(slots, now_s):
    hourly = em.spot_hourly(slots, now_s, SPOT_HOURS_SHOWN)
    current = em.spot_current(slots, now_s)
    if not hourly:
        return {"now": format_decimal(current * CENTS_PER_EURO if current is not None else None), "hours": [],
                "lo": MISSING, "hi": MISSING, "cheap": MISSING}
    lo, hi = min(p for _, p in hourly), max(p for _, p in hourly)
    span = hi - lo or 1
    cheap = em.spot_cheapest_window(hourly, CHEAP_WINDOW_HOURS)
    cheap_label = MISSING
    if cheap:
        start = datetime.datetime.fromtimestamp(cheap[0], em.HOUSE_ZONE)
        end = datetime.datetime.fromtimestamp(cheap[0] + CHEAP_WINDOW_HOURS * em.SECONDS_PER_HOUR, em.HOUSE_ZONE)
        cheap_label = f"{start.hour:02d} bis {end.hour:02d} Uhr, {format_decimal(cheap[1] * CENTS_PER_EURO, 1)} ct"
    hours = []
    for t, p in hourly:
        hour = datetime.datetime.fromtimestamp(t, em.HOUSE_ZONE).hour
        hours.append({"h": hour, "label": hour % SPOT_HOUR_LABEL_EVERY == 0,
                      "pct": round(SPOT_BAR_FLOOR_PERCENT + (p - lo) / span * (PERCENT - SPOT_BAR_FLOOR_PERCENT)),
                      "cheap": bool(cheap) and cheap[0] <= t < cheap[0] + CHEAP_WINDOW_HOURS * em.SECONDS_PER_HOUR})
    return {"now": format_decimal(current * CENTS_PER_EURO if current is not None else None, 1), "hours": hours,
            "lo": format_decimal(lo * CENTS_PER_EURO, 1), "hi": format_decimal(hi * CENTS_PER_EURO, 1),
            "cheap": cheap_label}


# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

def run(feed_dir, state_dir, now_s, urlopen=urllib.request.urlopen):
    """One sync: the payload, the gauges and the state, all from Prometheus and the price cache at now_s."""
    source = Source(PROMETHEUS, now_s, urlopen)
    now = datetime.datetime.fromtimestamp(now_s, em.HOUSE_ZONE)
    today = now.date()
    midnight_s, next_midnight_s = em.local_day_bounds(today)

    days_path = os.path.join(state_dir, "days.json")
    days = days_update((feed_io.file_json_load(days_path) or {}).get("days", {}), source, today, now_s)
    today_values = source.terms(today_terms(midnight_s, now_s))
    inputs = source.terms(inputs_terms(now_s))

    spot_path = os.path.join(state_dir, "spot.json")
    spot_cache = em.spot_cache_refresh(
        feed_io.file_json_load(spot_path), now_s,
        lambda first, last: em.spot_fetch(urlopen, SPOT_API, em.SPOT_ZONE, first, last))

    payload = {
        "view": "energy",
        "generated_at": now.isoformat(),
        "label": f"{WEEKDAYS[now.weekday()]} {now:%d.%m. %H:%M}",
        "now": section_now(source),
        "chart": section_chart(source, midnight_s, next_midnight_s, now_s),
        "today": section_today(today_values),
        "forecast": section_forecast(source),
        "history": section_history(days, today),
        "gas": section_meter(inputs or {}, "gas", now_s),
        "water": section_meter(inputs or {}, "water", now_s),
        "spot": section_spot(em.spot_cache_slots(spot_cache), now_s),
        "prices_missing": sum(1 for key in em.TARIFFS if f"tariff_{key}" not in inputs) if inputs is not None else 0,
        "source_ok": not source.failed,
    }

    shown_days, shown_months = periods_shown(
        days, {k: v for k, v in (today_values or {}).items() if k in em.PERIOD_TERMS}, today)
    os.makedirs(feed_dir, exist_ok=True)
    feed_io.file_write_atomic(os.path.join(feed_dir, "energy.json"), feed_io.json_dumps(payload))
    feed_io.file_write_atomic(os.path.join(state_dir, "energy.prom"), textfile_render(shown_days, shown_months))
    feed_io.file_write_atomic(days_path, feed_io.json_dumps({"days": days}))
    feed_io.file_write_atomic(spot_path, feed_io.json_dumps(spot_cache))
    feed_io.log(f"pv {payload['now']['pv']}, load {payload['now']['load']}, today {payload['today']['cost']} EUR, "
                f"spot {payload['spot']['now']} ct, {payload['prices_missing']} prices unset, "
                f"{len(days)} days cached, prometheus {'ok' if payload['source_ok'] else 'unreachable'}")
    return 0 if payload["source_ok"] else 1


def main():
    if len(sys.argv) != 3 or not PROMETHEUS:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    return run(sys.argv[1], sys.argv[2], time.time())


if __name__ == "__main__":
    sys.exit(main())
