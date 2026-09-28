"""Build the TRMNL energy payload: house power, gas, water and what they cost.

Usage: energy-sync.py <out-dir>

Reads Prometheus (fronius exporter, home assistant helpers) and the
energy-charts day-ahead prices, writes <out-dir>/energy.json. Labels are
German, the panel is read at home. The cost formula mirrors the Grafana
dashboard (modules/dashboards/energy.json); change both together.
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

PROMETHEUS = os.environ.get("ENERGY_PROMETHEUS", "http://10.100.0.105:9090")
SPOT_API = os.environ.get("ENERGY_SPOT_API", "https://api.energy-charts.info/price")
SPOT_ZONE = os.environ.get("ENERGY_SPOT_ZONE", "DE-LU")
TIMEOUT_S = 10

# chart viewbox, the template scales it to its box
CHART_W, CHART_H = 480, 120
# 5 minute samples: 288 points a day, fine at 480px
CHART_STEP_S = 300
HISTORY_DAYS = 14
# the cheapest block worth planning a wash or a charge around
CHEAP_WINDOW_H = 3
MONTH_S = 30.4375 * 86400
YEAR_S = 365.25 * 86400
COVER_MAX_S = 30 * 86400

LOAD = "fronius_load_watts"
PV = "fronius_pv_watts"
# ratios take both sides from watts, so a scrape gap biases neither
IMPORT_W = "clamp_min(fronius_grid_watts, 0)"
EXPORT_W = "clamp_min(-fronius_grid_watts, 0)"
SELF_W = f"({LOAD} - {IMPORT_W})"
IMPORT_WH = "fronius_meter_import_wh"
EXPORT_WH = "fronius_meter_export_wh"
GAS = 'hass_gas_meter_cubic_meters{entity="sensor.gas_meter_reading"}'
WATER = 'hass_water_meter_cubic_meters{entity="sensor.water_meter_reading"}'
HELPERS = ("price_electricity", "price_feed_in", "price_gas", "gas_kwh_per_m3", "price_water",
           "fee_electricity", "fee_gas", "fee_water")
WEEKDAYS = ("Mo", "Di", "Mi", "Do", "Fr", "Sa", "So")


# ---- sources ----------------------------------------------------------------------------------

def http_json(url):
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT_S) as r:
            return json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"{url[:80]}: {e}", file=sys.stderr)
        return None


def prom_query(query, at=None):
    """Instant query as a list of (labels, value); [] on error."""
    params = {"query": query}
    if at is not None:
        params["time"] = f"{at:.0f}"
    body = http_json(PROMETHEUS + "/api/v1/query?" + urllib.parse.urlencode(params))
    if not body or body.get("status") != "success":
        return []
    out = []
    for r in body["data"]["result"]:
        try:
            out.append((r["metric"], float(r["value"][1])))
        except (KeyError, TypeError, ValueError):
            continue
    return out


def prom_value(query, at=None):
    """First value of an instant query, or None."""
    rows = prom_query(query, at)
    return rows[0][1] if rows else None


def prom_range(query, start, end, step):
    """[(unix_seconds, value)] of the first series, or []."""
    params = {"query": query, "start": f"{start:.0f}", "end": f"{end:.0f}", "step": str(step)}
    body = http_json(PROMETHEUS + "/api/v1/query_range?" + urllib.parse.urlencode(params))
    if not body or body.get("status") != "success" or not body["data"]["result"]:
        return []
    return [(float(t), float(v)) for t, v in body["data"]["result"][0]["values"]]


def spot_fetch(start_day, end_day):
    """[(unix_seconds, eur_per_kwh)] quarter hours, sorted."""
    query = urllib.parse.urlencode({"bzn": SPOT_ZONE, "start": start_day.isoformat(), "end": end_day.isoformat()})
    body = http_json(f"{SPOT_API}?{query}")
    if not body:
        return []
    times, prices = body.get("unix_seconds") or [], body.get("price") or []
    if len(times) != len(prices):
        print(f"spot: {len(times)} times but {len(prices)} prices", file=sys.stderr)
        return []
    return sorted((t, p / 1000) for t, p in zip(times, prices) if p is not None)


# ---- energy over a window -----------------------------------------------------------------------

def energy_kwh(metric, window_s, at):
    """One-minute samples summed: a gap counts as nothing, like on the meter."""
    return prom_value(f"sum_over_time(({metric})[{window_s:.0f}s:1m]) / 60 / 1000", at)


def counter_delta(metric, window_s, at):
    """Rise of a monotonic reading over the window."""
    return prom_value(f"max_over_time({metric}[{window_s:.0f}s]) - min_over_time({metric}[{window_s:.0f}s])", at)


def window_energy(window_s, at):
    imp, exp = counter_delta(IMPORT_WH, window_s, at), counter_delta(EXPORT_WH, window_s, at)
    return {
        "pv": energy_kwh(PV, window_s, at),
        "load": energy_kwh(LOAD, window_s, at),
        "self": energy_kwh(SELF_W, window_s, at),
        "import_w": energy_kwh(IMPORT_W, window_s, at),
        "export_w": energy_kwh(EXPORT_W, window_s, at),
        "import": imp / 1000 if imp is not None else None,
        "export": exp / 1000 if exp is not None else None,
        "gas": counter_delta(GAS, window_s, at),
        "water": counter_delta(WATER, window_s, at),
    }


def cost_eur(e, prices, seconds):
    """Net cost of one window; unread meters and unset prices count 0."""
    p = {k: prices.get(k) or 0.0 for k in HELPERS}
    v = {k: e.get(k) or 0.0 for k in ("import", "export", "gas", "water", "self")}
    fees = (p["fee_electricity"] + p["fee_gas"] + p["fee_water"]) * seconds / MONTH_S
    parts = {
        "strom": v["import"] * p["price_electricity"],
        "gas": v["gas"] * p["gas_kwh_per_m3"] * p["price_gas"],
        "wasser": v["water"] * p["price_water"],
        "grund": fees,
        "einspeisung": v["export"] * p["price_feed_in"],
        "ersparnis": max(0.0, v["self"]) * p["price_electricity"],
    }
    parts["netto"] = parts["strom"] + parts["gas"] + parts["wasser"] + parts["grund"] - parts["einspeisung"]
    return parts


# ---- formatting ---------------------------------------------------------------------------------

def de(value, digits=1):
    """German decimal, '-' when unknown."""
    if value is None:
        return "-"
    s = f"{value:,.{digits}f}"
    return s.replace(",", "_").replace(".", ",").replace("_", ".")


def watts(value):
    if value is None:
        return "-"
    return f"{de(value / 1000, 2)} kW" if abs(value) >= 1000 else f"{value:.0f} W"


def age(seconds):
    if seconds is None:
        return "nie"
    if seconds < 3600:
        return f"vor {seconds // 60:.0f} min"
    if seconds < 86400:
        return f"vor {seconds // 3600:.0f} h"
    return f"vor {seconds // 86400:.0f} d"


def chart_path(points, t0, t1, v_max, close):
    """SVG path over [t0, t1] x [0, v_max]; closed paths are filled areas."""
    if not points or v_max <= 0:
        return ""
    xy = [((t - t0) / (t1 - t0) * CHART_W, CHART_H - min(v, v_max) / v_max * CHART_H) for t, v in points]
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in xy)
    if close:
        d += f" L{xy[-1][0]:.1f},{CHART_H} L{xy[0][0]:.1f},{CHART_H} Z"
    return d


# ---- panel sections -----------------------------------------------------------------------------

def section_now():
    grid = prom_value("fronius_grid_watts")
    battery = prom_value("fronius_battery_watts")
    soc = prom_value("fronius_battery_soc_ratio")
    return {
        "pv": watts(prom_value(PV)),
        "load": watts(prom_value(LOAD)),
        "grid": watts(abs(grid)) if grid is not None else "-",
        "grid_label": "Einspeisung" if grid is not None and grid < 0 else "Netzbezug",
        "battery": watts(abs(battery)) if battery is not None else "-",
        "battery_label": "entlädt" if battery and battery > 5 else ("lädt" if battery and battery < -5 else "ruht"),
        "soc": f"{soc * 100:.0f} %" if soc is not None else "-",
        "soc_pct": round(soc * 100) if soc is not None else 0,
        "online": prom_value('min(fronius_up)') == 1,
    }


def section_chart(midnight, now):
    t0, t1 = midnight.timestamp(), (midnight + timedelta(days=1)).timestamp()
    pv = prom_range(PV, t0, now.timestamp(), CHART_STEP_S)
    load = prom_range(LOAD, t0, now.timestamp(), CHART_STEP_S)
    soc = prom_range("fronius_battery_soc_ratio", t0, now.timestamp(), CHART_STEP_S)
    peak = max([v for _, v in pv + load] + [1000])
    # round the axis up to a whole kW
    top = -(-peak // 1000) * 1000
    return {
        "pv": chart_path(pv, t0, t1, top, close=True),
        "load": chart_path(load, t0, t1, top, close=False),
        "soc": chart_path(soc, t0, t1, 1.0, close=False),
        "top": f"{top / 1000:.0f} kW",
        "now_x": round((now.timestamp() - t0) / (t1 - t0) * CHART_W, 1),
    }


def section_today(midnight, now, prices):
    seconds = now.timestamp() - midnight.timestamp()
    e = window_energy(seconds, None)
    c = cost_eur(e, prices, seconds)
    load, pv = e["load"], e["pv"]
    autarky = 1 - e["import_w"] / load if load and e["import_w"] is not None else None
    self_use = 1 - e["export_w"] / pv if pv and e["export_w"] is not None else None
    return {
        "pv": de(pv), "load": de(load), "import": de(e["import"]), "export": de(e["export"]),
        "autarky": f"{max(0, min(1, autarky)) * 100:.0f} %" if autarky is not None else "-",
        "self_use": f"{max(0, min(1, self_use)) * 100:.0f} %" if self_use is not None else "-",
        "cost": de(c["netto"], 2), "saved": de(c["ersparnis"] + c["einspeisung"], 2),
    }


def section_forecast(prices):
    # step stays within the 5m lookback, or the first samples fall between steps
    first = prom_value(f"min_over_time(timestamp({LOAD})[30d:5m])")
    if first is None:
        return {"month": "-", "year": "-", "days": 0}
    covered = min(COVER_MAX_S, datetime.now().timestamp() - first)
    if covered < 3600:
        return {"month": "-", "year": "-", "days": 0}
    e = window_energy(COVER_MAX_S, None)
    c = cost_eur(e, prices, covered)
    return {"month": de(c["netto"] * MONTH_S / covered, 0), "year": de(c["netto"] * YEAR_S / covered, 0),
            "days": round(covered / 86400)}


def section_history(midnight):
    """Last HISTORY_DAYS full days, oldest first, bars scaled to the busiest day."""
    days = []
    for back in range(HISTORY_DAYS, 0, -1):
        start, end = midnight - timedelta(days=back), midnight - timedelta(days=back - 1)
        # dst days are 23h or 25h, so the window is measured, not assumed
        window = end.timestamp() - start.timestamp()
        at = end.timestamp()
        days.append({"label": WEEKDAYS[start.weekday()], "date": start.strftime("%d."),
                     "pv": energy_kwh(PV, window, at), "load": energy_kwh(LOAD, window, at)})
    top = max([d[k] or 0 for d in days for k in ("pv", "load")] + [1])
    for d in days:
        d["pv_pct"] = round((d["pv"] or 0) / top * 100)
        d["load_pct"] = round((d["load"] or 0) / top * 100)
        d["pv"], d["load"] = de(d["pv"]), de(d["load"])
    return {"days": days, "top": de(top, 0)}


def section_meter(metric, entity, price_key, prices, gas):
    reading = prom_value(metric)
    updated = prom_value(f'hass_last_updated_time_seconds{{entity="input_number.{entity}"}}')
    week = prom_value(f"{metric} - ({metric} offset 7d)")
    per_m3 = (prices.get(price_key) or 0) * ((prices.get("gas_kwh_per_m3") or 0) if gas else 1)
    return {
        "reading": de(reading, 3),
        "age": age(datetime.now().timestamp() - updated) if updated else "nie",
        "stale": updated is None or datetime.now().timestamp() - updated > 36 * 3600,
        "week": de(week, 2),
        "week_cost": de(week * per_m3, 2) if week is not None else "-",
    }


def section_spot(now):
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    slots = spot_fetch(today.date(), (today + timedelta(days=2)).date())
    ahead = [(t, p) for t, p in slots if t + 900 > now.timestamp()]
    if not ahead:
        return {"now": "-", "hours": [], "cheap": "-"}
    # hourly means for the strip; 24 bars fit the width
    hours = {}
    for t, p in ahead:
        hours.setdefault(int(t // 3600), []).append(p)
    hourly = [(h * 3600, sum(ps) / len(ps)) for h, ps in sorted(hours.items())][:24]
    lo, hi = min(p for _, p in hourly), max(p for _, p in hourly)
    span = hi - lo or 1
    # cheapest consecutive block of CHEAP_WINDOW_H hours
    cheap = None
    for i in range(len(hourly) - CHEAP_WINDOW_H + 1):
        mean = sum(p for _, p in hourly[i:i + CHEAP_WINDOW_H]) / CHEAP_WINDOW_H
        if cheap is None or mean < cheap[1]:
            cheap = (hourly[i][0], mean)
    cheap_label = "-"
    if cheap:
        a = datetime.fromtimestamp(cheap[0]).astimezone()
        b = a + timedelta(hours=CHEAP_WINDOW_H)
        cheap_label = f"{a.hour:02d} bis {b.hour:02d} Uhr, {de(cheap[1] * 100, 1)} ct"
    return {
        "now": de(ahead[0][1] * 100, 1),
        # floor at 25%: the cheap bars are the short ones and must stay visible
        "hours": [{"h": datetime.fromtimestamp(t).astimezone().hour, "pct": round(25 + (p - lo) / span * 75),
                   "cheap": bool(cheap) and cheap[0] <= t < cheap[0] + CHEAP_WINDOW_H * 3600,
                   "label": datetime.fromtimestamp(t).astimezone().hour % 6 == 0}
                  for t, p in hourly],
        "lo": de(lo * 100, 1), "hi": de(hi * 100, 1),
        "cheap": cheap_label,
    }


def prices_fetch():
    rows = prom_query('{__name__=~"hass_input_number_state.*", entity=~"input_number.(price|fee|gas_kwh).*"}')
    return {m["entity"].split(".", 1)[1]: v for m, v in rows}


# ---- main ---------------------------------------------------------------------------------------

def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    if len(sys.argv) != 2:
        print("usage: energy-sync.py <out-dir>", file=sys.stderr)
        return 2
    out_dir = sys.argv[1]

    now = datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    prices = prices_fetch()
    missing = [k for k in HELPERS if not prices.get(k)]

    payload = {
        "view": "energy",
        "generated_at": now.isoformat(),
        "label": f"{WEEKDAYS[now.weekday()]} {now:%d.%m. %H:%M}",
        "now": section_now(),
        "chart": section_chart(midnight, now),
        "today": section_today(midnight, now, prices),
        "forecast": section_forecast(prices),
        "history": section_history(midnight),
        "gas": section_meter(GAS, "gas_meter", "price_gas", prices, gas=True),
        "water": section_meter(WATER, "water_meter", "price_water", prices, gas=False),
        "spot": section_spot(now),
        "prices_missing": len(missing),
    }

    os.makedirs(out_dir, exist_ok=True)
    write_atomic(os.path.join(out_dir, "energy.json"), json.dumps(payload, indent=2, ensure_ascii=False))
    print(f"pv {payload['now']['pv']}, load {payload['now']['load']}, today {payload['today']['cost']} EUR, "
          f"spot {payload['spot']['now']} ct, {len(missing)} prices unset")
    return 0


if __name__ == "__main__":
    sys.exit(main())
