"""Grafana dashboard "Energie": house power, gas, water and their cost.

Usage: energy.py <out.json>   (run by nix at build time, see 105-internal-grafana.nix)

Sources: fronius-exporter.py (power, meter, battery), spot-price.py (day-ahead
price) and the Home Assistant helpers on vm-125 (meter readings, tariffs).
Labels are German. energy-sync.py computes the same costs for the TRMNL
panel; change both together.

Energy is one-minute samples summed, so a scrape gap counts as nothing, the
same as on the grid meter. Averaging times the window would fill gaps with
the mean and disagree with the meter after every outage.
"""
import json
import sys

DS = {"type": "prometheus", "uid": "prometheus"}

PV = "fronius_pv_watts"
LOAD = "fronius_load_watts"
GRID = "fronius_grid_watts"
BAT = "fronius_battery_watts"
GAS = 'hass_gas_meter_cubic_meters{entity="sensor.gas_meter_reading"}'
WATER = 'hass_water_meter_cubic_meters{entity="sensor.water_meter_reading"}'


def energy_kwh(expr, window="$__range"):
    return f"sum_over_time(({expr})[{window}:1m]) / 60 / 1000"


def delta(metric, window="$__range"):
    """Rise of a monotonic reading over the window."""
    return f"(max_over_time({metric}[{window}]) - min_over_time({metric}[{window}]))"


def counter_kwh(metric, window="$__range"):
    return f"{delta(metric, window)} / 1000"


IMPORT_W = f"clamp_min({GRID}, 0)"
EXPORT_W = f"clamp_min(-{GRID}, 0)"
DISCHARGE_W = f"clamp_min({BAT}, 0)"
CHARGE_W = f"clamp_min(-{BAT}, 0)"

# grid layout state: panels flow left to right in 24 columns
panels = []
y, x_cursor, row_h = 0, 0, 0


def place(panel, w, h):
    """Left to right, wrapping at 24 columns."""
    global y, x_cursor, row_h
    if x_cursor + w > 24:
        y += row_h
        x_cursor, row_h = 0, 0
    panel["gridPos"] = {"x": x_cursor, "y": y, "w": w, "h": h}
    x_cursor += w
    row_h = max(row_h, h)
    panels.append(panel)


def row(title):
    global y, x_cursor, row_h
    y += row_h
    x_cursor, row_h = 0, 0
    panels.append({"type": "row", "title": title, "collapsed": False, "panels": [],
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}})
    y += 1


def target(expr, legend="", ref="A", instant=False, interval=None):
    t = {"refId": ref, "datasource": DS, "expr": expr, "legendFormat": legend or "__auto",
         "instant": instant, "range": not instant}
    if interval:
        t["interval"] = interval
    return t


def thresholds(*steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}


def stat(title, expr, unit, decimals=None, color="blue", steps=None, description=None, graph=False):
    d = {"unit": unit, "color": {"mode": "thresholds"}, "noValue": "-",
         "thresholds": thresholds(*(steps or [(None, color)]))}
    if decimals is not None:
        d["decimals"] = decimals
    p = {"type": "stat", "title": title, "datasource": DS,
         "fieldConfig": {"defaults": d, "overrides": []},
         "options": {"colorMode": "background", "graphMode": "area" if graph else "none",
                     "justifyMode": "center", "textMode": "value", "wideLayout": True,
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
         "targets": [target(expr, instant=not graph)]}
    if description:
        p["description"] = description
    return p


def gauge(title, expr, unit, lo, hi, steps, description=None):
    p = {"type": "gauge", "title": title, "datasource": DS,
         "fieldConfig": {"defaults": {"unit": unit, "min": lo, "max": hi, "color": {"mode": "thresholds"},
                                      "thresholds": thresholds(*steps)}, "overrides": []},
         "options": {"showThresholdLabels": False, "showThresholdMarkers": True,
                     "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
         "targets": [target(expr, instant=True)]}
    if description:
        p["description"] = description
    return p


def series(title, targets, unit, stack=False, fill=10, bars=False, decimals=None, colors=None,
           description=None, time_from=None, interval=None, min_value=None, max_value=None, legend_calcs=None):
    custom = {"drawStyle": "bars" if bars else "line", "lineWidth": 1, "fillOpacity": 80 if bars else fill,
              "showPoints": "never", "spanNulls": False, "lineInterpolation": "linear",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"}}
    d = {"unit": unit, "custom": custom, "color": {"mode": "palette-classic"}}
    if decimals is not None:
        d["decimals"] = decimals
    if min_value is not None:
        d["min"] = min_value
    if max_value is not None:
        d["max"] = max_value
    overrides = []
    for name, color in (colors or {}).items():
        overrides.append({"matcher": {"id": "byName", "options": name},
                          "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]})
    p = {"type": "timeseries", "title": title, "datasource": DS,
         "fieldConfig": {"defaults": d, "overrides": overrides},
         "options": {"tooltip": {"mode": "multi", "sort": "none"},
                     "legend": {"displayMode": "table" if legend_calcs else "list", "placement": "bottom",
                                "calcs": legend_calcs or []}},
         "targets": targets}
    if description:
        p["description"] = description
    if time_from:
        p["timeFrom"] = time_from
    if interval:
        p["interval"] = interval
    return p


def helper_series(key):
    """A typed-in HA helper; the metric name carries its escaped unit, so match by entity."""
    return f'{{__name__=~"hass_input_number_state.*", entity="input_number.{key}"}}'


def helper(key):
    return f"scalar({helper_series(key)})"


P_EL, P_FEED, P_GAS = helper("price_electricity"), helper("price_feed_in"), helper("price_gas")
GAS_KWH, P_WATER = helper("gas_kwh_per_m3"), helper("price_water")
FEES = f'({helper("fee_electricity")} + {helper("fee_gas")} + {helper("fee_water")})'
SPOT_SERIES = 'energy_spot_price_eur_per_kwh{zone="DE-LU"}'
SPOT = f"scalar({SPOT_SERIES})"
MONTH_S = 30.4375 * 86400


def costs(window, seconds):
    """Cost terms over one window, in EUR."""
    imp = counter_kwh("fronius_meter_import_wh", window)
    exp = counter_kwh("fronius_meter_export_wh", window)
    # sum drops the source labels so fronius and hass terms add up; an unread meter counts 0
    return {k: f"(sum({v}) or vector(0))" for k, v in {
        "Strom": f"({imp}) * {P_EL}",
        "Gas": f"{delta(GAS, window)} * {GAS_KWH} * {P_GAS}",
        "Wasser": f"{delta(WATER, window)} * {P_WATER}",
        "Einspeisung": f"({exp}) * {P_FEED}",
        "PV-Ersparnis": f"({energy_kwh(f'{LOAD} - {IMPORT_W}', window)}) * {P_EL}",
    }.items()} | {"Grundpreise": f"({FEES} * {seconds} / {MONTH_S})"}


def net(c):
    return f"({c['Strom']}) + ({c['Gas']}) + ({c['Wasser']}) + ({c['Grundpreise']}) - ({c['Einspeisung']})"


COLORS = {"PV": "yellow", "Verbrauch": "red", "Netz": "blue", "Batterie": "green",
          "Bezug": "blue", "Einspeisung": "purple", "Laden": "green", "Entladen": "dark-green",
          "Eigenverbrauch": "yellow", "Erzeugt": "yellow", "Verbraucht": "red", "Gas": "orange",
          "Wasser": "blue", "Strom": "red", "Grundpreise": "text", "Vertrag": "red", "Börse": "blue"}
DAY, WEEK = "1d", "7d"

# ---- jetzt --------------------------------------------------------------------------------
row("Jetzt")
place(stat("PV", PV, "watt", 0, "yellow", graph=True), 4, 5)
place(stat("Verbrauch", LOAD, "watt", 0, "red", graph=True), 4, 5)
place(stat("Netz", GRID, "watt", 0, steps=[(None, "purple"), (0, "blue")], graph=True,
           description="Positiv ist Bezug, negativ ist Einspeisung."), 4, 5)
place(stat("Batterie", BAT, "watt", 0, steps=[(None, "green"), (0, "dark-green")], graph=True,
           description="Positiv ist Entladen, negativ ist Laden."), 4, 5)
place(gauge("Ladestand", "fronius_battery_soc_ratio", "percentunit", 0, 1,
            [(None, "red"), (0.2, "orange"), (0.5, "green")]), 4, 5)
place(stat("Börsenstrompreis", SPOT_SERIES, "currencyEUR", 3,
           steps=[(None, "green"), (0.10, "orange"), (0.20, "red")],
           description="Day-Ahead-Preis der aktuellen Viertelstunde, ohne Netzentgelte, Abgaben und MwSt."), 4, 5)

# ---- zeitraum -----------------------------------------------------------------------------
row("Energie im gewählten Zeitraum")
place(stat("Erzeugt", energy_kwh(PV), "kwatth", 2, "yellow"), 4, 4)
place(stat("Verbraucht", energy_kwh(LOAD), "kwatth", 2, "red"), 4, 4)
place(stat("Netzbezug", counter_kwh("fronius_meter_import_wh"), "kwatth", 2, "blue"), 4, 4)
place(stat("Einspeisung", counter_kwh("fronius_meter_export_wh"), "kwatth", 2, "purple"), 4, 4)
place(stat("Batterie geladen", energy_kwh(CHARGE_W), "kwatth", 2, "green"), 4, 4)
place(stat("Batterie entladen", energy_kwh(DISCHARGE_W), "kwatth", 2, "dark-green"), 4, 4)
# both sides from watts: a scrape gap biases neither
place(stat("Autarkie", f"clamp(1 - avg_over_time({IMPORT_W}[$__range:]) / avg_over_time({LOAD}[$__range:]), 0, 1)",
           "percentunit", 0, steps=[(None, "red"), (0.5, "orange"), (0.8, "green")],
           description="Anteil des Verbrauchs, der nicht aus dem Netz kommt."), 6, 4)
place(stat("Eigenverbrauchsquote", f"clamp(1 - avg_over_time({EXPORT_W}[$__range:]) / avg_over_time({PV}[$__range:]), 0, 1)",
           "percentunit", 0, steps=[(None, "red"), (0.3, "orange"), (0.6, "green")],
           description="Anteil der Erzeugung, der im Haus oder in der Batterie bleibt."), 6, 4)
place(stat("Gas", delta(GAS), "m3", 2, "orange"), 6, 4)
place(stat("Wasser", delta(WATER), "m3", 2, "blue"), 6, 4)

# ---- kosten -------------------------------------------------------------------------------
row("Kosten")
RANGE = costs("$__range", "$__range_s")
place(stat("Kosten netto", net(RANGE), "currencyEUR", 2, "red",
           description="Strombezug, Gas, Wasser und anteilige Grundpreise, abzüglich Einspeisevergütung."), 4, 4)
place(stat("Strombezug", RANGE["Strom"], "currencyEUR", 2, "red"), 4, 4)
place(stat("Gas", RANGE["Gas"], "currencyEUR", 2, "orange"), 4, 4)
place(stat("Wasser", RANGE["Wasser"], "currencyEUR", 2, "blue"), 4, 4)
place(stat("Einspeisevergütung", RANGE["Einspeisung"], "currencyEUR", 2, "purple"), 4, 4)
place(stat("PV-Ersparnis", RANGE["PV-Ersparnis"], "currencyEUR", 2, "green",
           description="Selbst gedeckter Verbrauch zum Vertragspreis: "
                       "was ohne PV und Batterie zusätzlich angefallen wäre."), 4, 4)
# seconds of the last 30 days that have data, so a young history is not read as a cheap month
# step stays within the 5m lookback, or the first samples fall between steps
COVERED_S = f"scalar(clamp_max(vector(time() - scalar(min_over_time(timestamp({LOAD})[30d:5m]))), {30 * 86400}))"
LAST30 = costs("30d", COVERED_S)
place(stat("Prognose Monat", f"({net(LAST30)}) * {MONTH_S} / {COVERED_S}", "currencyEUR", 0, "red",
           description="Hochgerechnet aus den letzten 30 Tagen."), 6, 4)
place(stat("Prognose Jahr", f"({net(LAST30)}) * {365.25 * 86400} / {COVERED_S}", "currencyEUR", 0, "red",
           description="Hochgerechnet aus den letzten 30 Tagen, ohne Saisonverlauf."), 6, 4)
place(stat("PV-Ersparnis Prognose Jahr", f"({LAST30['PV-Ersparnis']} + {LAST30['Einspeisung']}) * {365.25 * 86400} / {COVERED_S}",
           "currencyEUR", 0, "green", description="Ersparnis und Vergütung der letzten 30 Tage, hochgerechnet."), 6, 4)
place(stat("Bezug zum Börsenpreis",
           # on(): a step without a spot price drops out instead of turning the average NaN
           energy_kwh(f"{IMPORT_W} * on() group_left() {SPOT_SERIES}"),
           "currencyEUR", 2, "blue",
           description="Derselbe Netzbezug zum Day-Ahead-Preis, ohne Abgaben: "
                       "der Großhandelsanteil eines dynamischen Tarifs."), 6, 4)
PER_DAY = costs(DAY, "86400")
place(series("Kosten pro Tag", [
    target(PER_DAY["Strom"], "Strom", interval=DAY),
    target(PER_DAY["Gas"], "Gas", "B", interval=DAY),
    target(PER_DAY["Wasser"], "Wasser", "C", interval=DAY),
    target(PER_DAY["Grundpreise"], "Grundpreise", "D", interval=DAY),
    target(f"-({PER_DAY['Einspeisung']})", "Einspeisung", "E", interval=DAY)],
    "currencyEUR", bars=True, stack=True, decimals=2, colors=COLORS, time_from="30d", legend_calcs=["sum", "mean"],
    description="Einspeisevergütung negativ. Tage enden um Mitternacht UTC."), 24, 9)
place(series("Strompreis", [
    target(SPOT_SERIES, "Börse"),
    target(helper_series("price_electricity"), "Vertrag", "B")], "currencyEUR", decimals=3, colors=COLORS,
    legend_calcs=["min", "mean", "max"], description="Börse ohne Netzentgelte, Abgaben und MwSt."), 24, 8)

# ---- leistung -----------------------------------------------------------------------------
row("Leistung")
place(series("Leistung", [target(PV, "PV"), target(LOAD, "Verbrauch", "B"), target(GRID, "Netz", "C"),
                          target(BAT, "Batterie", "D")], "watt", colors=COLORS,
             legend_calcs=["mean", "max"]), 24, 10)
place(series("Woher der Verbrauch kommt", [
    target(f"{LOAD} - {IMPORT_W} - {DISCHARGE_W}", "Eigenverbrauch"),
    target(DISCHARGE_W, "Entladen", "B"),
    target(IMPORT_W, "Bezug", "C")], "watt", stack=True, fill=60, colors=COLORS, min_value=0), 12, 9)
place(series("Wohin die PV geht", [
    target(f"{PV} - {EXPORT_W} - {CHARGE_W}", "Eigenverbrauch"),
    target(CHARGE_W, "Laden", "B"),
    target(EXPORT_W, "Einspeisung", "C")], "watt", stack=True, fill=60, colors=COLORS, min_value=0), 12, 9)
place(series("Autarkie und Eigenverbrauch, gleitend 1h", [
    target(f"clamp(1 - avg_over_time({IMPORT_W}[1h:]) / avg_over_time({LOAD}[1h:]), 0, 1)", "Autarkie"),
    target(f"clamp(1 - avg_over_time({EXPORT_W}[1h:]) / avg_over_time({PV}[1h:]), 0, 1)", "Eigenverbrauch", "B")],
    "percentunit", min_value=0, max_value=1), 12, 8)
place(series("Grundlast", [target(f"quantile_over_time(0.05, {LOAD}[24h])", "Grundlast")],
             "watt", colors={"Grundlast": "red"}, time_from="30d",
             description="5%-Quantil der letzten 24h: was das Haus zieht, wenn nichts läuft."), 12, 8)

# ---- verlauf ------------------------------------------------------------------------------
row("Verlauf")
place(series("Energie pro Tag", [
    target(energy_kwh(PV, DAY), "Erzeugt", interval=DAY),
    target(energy_kwh(LOAD, DAY), "Verbraucht", "B", interval=DAY),
    target(counter_kwh("fronius_meter_import_wh", DAY), "Bezug", "C", interval=DAY),
    target(counter_kwh("fronius_meter_export_wh", DAY), "Einspeisung", "D", interval=DAY)],
    "kwatth", bars=True, decimals=1, colors=COLORS, time_from="30d", legend_calcs=["sum", "mean"],
    description="Tage enden um Mitternacht UTC."), 24, 9)
place(series("Energie pro Woche", [
    target(energy_kwh(PV, WEEK), "Erzeugt", interval=WEEK),
    target(energy_kwh(LOAD, WEEK), "Verbraucht", "B", interval=WEEK),
    target(counter_kwh("fronius_meter_import_wh", WEEK), "Bezug", "C", interval=WEEK),
    target(counter_kwh("fronius_meter_export_wh", WEEK), "Einspeisung", "D", interval=WEEK)],
    "kwatth", bars=True, decimals=0, colors=COLORS, time_from="1y", legend_calcs=["sum", "mean"]), 24, 9)
place(series("Wechselrichter gesamt", [target("fronius_inverter_energy_total_wh / 1000", "Gesamt")],
             "kwatth", decimals=0, time_from="1y"), 12, 7)
place(series("Zähler gesamt", [
    target("fronius_meter_import_wh / 1000", "Bezug"),
    target("fronius_meter_export_wh / 1000", "Einspeisung", "B")], "kwatth", decimals=0, colors=COLORS,
    time_from="1y"), 12, 7)

# ---- gas und wasser -----------------------------------------------------------------------
row("Gas und Wasser")
place(stat("Gaszähler", GAS, "m3", 3, "orange"), 4, 4)
place(stat("Wasserzähler", WATER, "m3", 3, "blue"), 4, 4)
place(stat("Gas abgelesen vor", 'time() - hass_last_updated_time_seconds{entity="input_number.gas_meter"}', "s", 0,
           steps=[(None, "green"), (129600, "orange"), (259200, "red")],
           description="Seit dem letzten eingetragenen Stand; orange nach 36h."), 4, 4)
place(stat("Wasser abgelesen vor", 'time() - hass_last_updated_time_seconds{entity="input_number.water_meter"}', "s", 0,
           steps=[(None, "green"), (129600, "orange"), (259200, "red")]), 4, 4)
place(stat("Gas, letzte 7 Tage", f"{GAS} - ({GAS} offset 7d)", "m3", 2, "orange"), 4, 4)
place(stat("Wasser, letzte 7 Tage", f"{WATER} - ({WATER} offset 7d)", "m3", 2, "blue"), 4, 4)
place(series("Gas pro Tag", [target(f"{GAS} - ({GAS} offset 1d)", "Gas", interval=DAY)], "m3", bars=True,
             decimals=2, colors=COLORS, time_from="60d", legend_calcs=["sum", "mean"]), 12, 8)
place(series("Wasser pro Tag", [target(f"{WATER} - ({WATER} offset 1d)", "Wasser", interval=DAY)], "m3",
             bars=True, decimals=2, colors=COLORS, time_from="60d", legend_calcs=["sum", "mean"]), 12, 8)
place(series("Gas pro Woche", [target(f"{GAS} - ({GAS} offset 7d)", "Gas", interval=WEEK)], "m3", bars=True,
             decimals=1, colors=COLORS, time_from="1y"), 12, 7)
place(series("Wasser pro Woche", [target(f"{WATER} - ({WATER} offset 7d)", "Wasser", interval=WEEK)], "m3",
             bars=True, decimals=1, colors=COLORS, time_from="1y"), 12, 7)

# ---- batterie -----------------------------------------------------------------------------
row("Batterie")
place(series("Ladestand", [target("fronius_battery_soc_ratio", "Ladestand")], "percentunit", min_value=0, max_value=1,
             colors={"Ladestand": "green"}), 12, 8)
place(series("Leistung", [target(BAT, "Batterie")], "watt", colors=COLORS,
             description="Positiv ist Entladen."), 12, 8)
place(series("Zelltemperatur", [target("fronius_battery_temperature_celsius", "Zellen")], "celsius"), 8, 7)
place(series("DC-Strom", [target("fronius_battery_current_amperes", "Strom")], "amp"), 8, 7)
place(stat("Vollzyklen im Zeitraum", f"({energy_kwh(DISCHARGE_W)}) / (fronius_battery_capacity_wh / 1000)",
           "short", 2, "green", description="Entladene Energie geteilt durch Kapazität."), 4, 7)
place(stat("Kapazität", "fronius_battery_capacity_wh / 1000", "kwatth", 1, "green"), 4, 7)

# ---- netzzähler ---------------------------------------------------------------------------
row("Netzzähler")
place(series("Leistung je Phase", [target("fronius_meter_power_watts", "L{{phase}}")], "watt",
             legend_calcs=["mean", "max"], description="Positiv ist Bezug."), 12, 8)
place(series("Spannung", [target("fronius_meter_voltage_volts", "L{{phase}}")], "volt",
             legend_calcs=["min", "max"]), 12, 8)
place(series("Strom", [target("fronius_meter_current_amperes", "L{{phase}}")], "amp",
             legend_calcs=["mean", "max"]), 8, 8)
place(series("Leistungsfaktor", [target("fronius_meter_power_factor", "L{{phase}}")], "short"), 8, 8)
place(series("Blindleistung", [target("fronius_meter_reactive_power_var", "L{{phase}}")], "short"), 8, 8)
place(series("Außenleiterspannung", [target("fronius_meter_voltage_phase_to_phase_volts", "L{{phases}}")],
             "volt"), 12, 7)
place(series("Netzfrequenz", [target("fronius_meter_frequency_hertz", "Netz")], "hertz", decimals=2), 12, 7)
place(series("Schieflast", [target("max(fronius_meter_power_watts) - min(fronius_meter_power_watts)",
                                   "Max - Min")], "watt",
             description="Abstand zwischen der am stärksten und der am schwächsten belasteten Phase."), 24, 7)

# ---- wechselrichter -----------------------------------------------------------------------
row("Wechselrichter")
place(series("AC-Leistung", [target("fronius_inverter_ac_watts", "AC")], "watt"), 8, 7)
place(series("DC-Eingang", [target("fronius_inverter_dc_volts", "Spannung"),
                            target("fronius_inverter_dc_amperes", "Strom", "B")], "short"), 8, 7)
place(stat("Statuscode", "fronius_inverter_status_code", "none", 0, "blue"), 4, 7)
place(stat("Fehlercode", "fronius_inverter_error_code", "none", 0, steps=[(None, "green"), (1, "red")]), 4, 7)
place({"type": "state-timeline", "title": "Solar API erreichbar", "datasource": DS,
       "fieldConfig": {"defaults": {"color": {"mode": "thresholds"},
                                    "thresholds": thresholds((None, "red"), (1, "green")),
                                    "mappings": [{"type": "value", "options": {
                                        "0": {"text": "weg"}, "1": {"text": "da"}}}]},
                       "overrides": []},
       "options": {"showValue": "never", "rowHeight": 0.8, "mergeValues": True},
       "targets": [target("fronius_up", "{{endpoint}}")]}, 24, 6)

dashboard = {
    "title": "Energie",
    "uid": "energy",
    "tags": ["energie", "haus"],
    "timezone": "browser",
    "editable": True,
    "graphTooltip": 1,
    "schemaVersion": 41,
    # today, midnight to midnight
    "time": {"from": "now/d", "to": "now/d"},
    "refresh": "30s",
    "templating": {"list": []},
    "panels": panels,
}

with open(sys.argv[1], "w") as f:
    json.dump(dashboard, f, indent=2, ensure_ascii=False)
