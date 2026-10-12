"""Grafana dashboard "Energie": house power, gas, water and their cost.

Usage: energy.py <out.json>   (run by nix at build time, see 105-internal-grafana.nix)

Every query comes from energy_model (modules/energy), the same definitions instances/104-internal-terminal/lib/energy-sync.py evaluates for
the TRMNL panel, so the board and the panel cannot disagree. Labels are German, the board is read at home.

Per-day and per-month bars read energy-sync's gauges (homelab_energy_day_*, homelab_energy_month_*), which hold
totals over local days and months. Rejected alternative: interval="1d" buckets align to the epoch, so a "day" ran
from 01:00 or 02:00 local time and a week started on a Thursday.
"""
import sys

import energy_model as em
from grafana import bar_chart, dashboard, dashboard_write, gauge, section, series, stat, state_timeline, target

# ---- constants ----------------------------------------------------------------------------------

COLORS = {"PV": "yellow", "Verbrauch": "red", "Netz": "blue", "Batterie": "green", "Nicht erfasst": "orange",
          "Bezug": "blue", "Einspeisung": "purple", "Laden": "green", "Entladen": "dark-green",
          "Eigenverbrauch": "yellow", "pv": "yellow", "load": "red", "import": "blue", "export": "purple",
          "electricity": "red", "gas": "orange", "water": "blue", "base_fees": "text", "feed_in": "purple",
          "Vertrag": "red", "Börse": "blue"}
# the board's default range: today, local midnight to midnight
TODAY = ("now/d", "now/d")
DAYS_SHOWN = em.PERIOD_COUNTS["day"]
MONTHS_SHOWN = em.PERIOD_COUNTS["month"]
EURO_DIGITS = 2

RANGE = em.WINDOW_RANGE
ENERGY = em.energy_terms(RANGE)
COSTS = em.cost_terms(RANGE)
LAST30 = em.cost_terms(em.window_from_seconds(em.COVERAGE_S), fee_seconds=em.covered_seconds())


def period_bars(title, period, unit, terms, decimals, description, negative=()):
    """energy-sync's gauges of one unit over local days or months, one bar group per period."""
    label = em.PERIOD_TERMS[terms[0]][1]
    values = "|".join(em.PERIOD_TERMS[t][2] for t in terms if em.PERIOD_TERMS[t][2] not in negative)
    metric = em.period_metric(period, unit)
    expr = f'{metric}{{{label}=~"{values}"}}'
    for value in negative:
        expr += f' or -{metric}{{{label}="{value}"}}'
    return bar_chart(title, [target(expr, instant=True)], unit_grafana(unit), period, label, decimals=decimals,
                     colors=COLORS, stack=unit == "eur", description=description)


def unit_grafana(unit):
    return {"kwh": "kwatth", "eur": "currencyEUR", "m3": "m3"}[unit]


def reading_age(meter):
    return f"time() - {em.METERS[meter]['readAtMetric']}"


# ---- sections -----------------------------------------------------------------------------------

now = section(
    "Jetzt",
    (stat("PV", [target(em.PV_W)], "watt", 0, "yellow", graph=True), 4, 5),
    (stat("Verbrauch", [target(em.LOAD_W)], "watt", 0, "red", graph=True,
          description="Fehlt, solange eine Erzeugung läuft, die der Wechselrichter nicht sieht (Nicht erfasst)."), 4, 5),
    (stat("Netz", [target(em.GRID_W)], "watt", 0, steps=[(None, "purple"), (0, "blue")], graph=True,
          description="Positiv ist Bezug, negativ ist Einspeisung."), 4, 5),
    (stat("Batterie", [target(em.BATTERY_W)], "watt", 0, steps=[(None, "green"), (0, "dark-green")], graph=True,
          description="Positiv ist Entladen, negativ ist Laden."), 4, 5),
    (gauge("Ladestand", [target(em.SOC_RATIO, instant=True)], "percentunit", 0, 1,
           [(None, "red"), (0.2, "orange"), (0.5, "green")]), 4, 5),
    (stat("Börsenstrompreis", [target(em.SPOT_SERIES, instant=True)], "currencyEUR", 3,
          steps=[(None, "green"), (0.10, "orange"), (0.20, "red")],
          description="Day-Ahead-Preis der aktuellen Viertelstunde, ohne Netzentgelte, Abgaben und MwSt."), 4, 5),
)

energy = section(
    "Energie im gewählten Zeitraum",
    (stat("Erzeugt", [target(ENERGY["pv_kwh"], instant=True)], "kwatth", 2, "yellow"), 4, 4),
    (stat("Verbraucht", [target(ENERGY["load_kwh"], instant=True)], "kwatth", 2, "red",
          description="Ohne die Minuten mit nicht erfasster Erzeugung, dort ist der Verbrauch unbekannt."), 4, 4),
    (stat("Netzbezug", [target(ENERGY["import_kwh"], instant=True)], "kwatth", 2, "blue"), 4, 4),
    (stat("Einspeisung", [target(ENERGY["export_kwh"], instant=True)], "kwatth", 2, "purple"), 4, 4),
    (stat("Batterie geladen", [target(ENERGY["charge_kwh"], instant=True)], "kwatth", 2, "green"), 4, 4),
    (stat("Batterie entladen", [target(ENERGY["discharge_kwh"], instant=True)], "kwatth", 2, "dark-green"), 4, 4),
    (stat("Autarkie", [target(f"clamp(1 - ({ENERGY['import_known_load_kwh']}) / ({ENERGY['load_kwh']}), 0, 1)",
                              instant=True)],
          "percentunit", 0, steps=[(None, "red"), (0.5, "orange"), (0.8, "green")],
          description="Anteil des Verbrauchs, der nicht aus dem Netz kommt."), 6, 4),
    (stat("Eigenverbrauchsquote", [target(f"clamp(1 - ({ENERGY['export_known_pv_kwh']}) / ({ENERGY['pv_kwh']}), 0, 1)",
                                          instant=True)],
          "percentunit", 0, steps=[(None, "red"), (0.3, "orange"), (0.6, "green")],
          description="Anteil der Erzeugung, der im Haus oder in der Batterie bleibt."), 6, 4),
    (stat("Gas", [target(ENERGY["gas_m3"], instant=True)], "m3", 2, "orange"), 6, 4),
    (stat("Wasser", [target(ENERGY["water_m3"], instant=True)], "m3", 2, "blue"), 6, 4),
)

costs = section(
    "Kosten",
    (stat("Kosten netto", [target(em.cost_net(COSTS), instant=True)], "currencyEUR", EURO_DIGITS, "red",
          description="Strombezug, Gas, Wasser und anteilige Grundpreise, abzüglich Einspeisevergütung. "
                      "Fehlt, solange ein Preis oder ein Zählerstand fehlt."), 4, 4),
    (stat("Strombezug", [target(COSTS["electricity_eur"], instant=True)], "currencyEUR", EURO_DIGITS, "red"), 4, 4),
    (stat("Gas", [target(COSTS["gas_eur"], instant=True)], "currencyEUR", EURO_DIGITS, "orange"), 4, 4),
    (stat("Wasser", [target(COSTS["water_eur"], instant=True)], "currencyEUR", EURO_DIGITS, "blue"), 4, 4),
    (stat("Einspeisevergütung", [target(COSTS["feed_in_eur"], instant=True)], "currencyEUR", EURO_DIGITS,
          "purple"), 4, 4),
    (stat("PV-Ersparnis", [target(COSTS["pv_savings_eur"], instant=True)], "currencyEUR", EURO_DIGITS, "green",
          description="Selbst gedeckter Verbrauch zum Vertragspreis: "
                      "was ohne PV und Batterie zusätzlich angefallen wäre."), 4, 4),
    (stat("Prognose Monat", [target(em.cost_forecast(LAST30, em.SECONDS_PER_MONTH), instant=True)], "currencyEUR",
          0, "red", description="Hochgerechnet aus den letzten 30 Tagen."), 6, 4),
    (stat("Prognose Jahr", [target(em.cost_forecast(LAST30, em.SECONDS_PER_YEAR), instant=True)], "currencyEUR",
          0, "red", description="Hochgerechnet aus den letzten 30 Tagen, ohne Saisonverlauf."), 6, 4),
    (stat("PV-Ersparnis Prognose Jahr",
          [target(f"({em.cost_savings(LAST30)}) * {em.SECONDS_PER_YEAR} / {em.covered_seconds()}", instant=True)],
          "currencyEUR", 0, "green", description="Ersparnis und Vergütung der letzten 30 Tage, hochgerechnet."), 6, 4),
    (stat("Bezug zum Börsenpreis", [target(em.import_at_spot_eur(RANGE), instant=True)], "currencyEUR",
          EURO_DIGITS, "blue",
          description="Derselbe Netzbezug zum Day-Ahead-Preis, ohne Abgaben: "
                      "der Großhandelsanteil eines dynamischen Tarifs."), 6, 4),
    (period_bars("Kosten pro Tag", "day", "eur",
                 ["electricity_eur", "gas_eur", "water_eur", "base_fees_eur", "feed_in_eur"], EURO_DIGITS,
                 f"Die letzten {DAYS_SHOWN} Tage, lokale Tage. Einspeisevergütung negativ.",
                 negative=("feed_in",)), 24, 9),
    (series("Strompreis", [target(em.SPOT_SERIES, "Börse"), target(em.tariff_selector("price_electricity"), "Vertrag")],
            "currencyEUR", decimals=3, colors=COLORS, legend_calcs=["min", "mean", "max"],
            description="Börse ohne Netzentgelte, Abgaben und MwSt."), 24, 8),
)

power = section(
    "Leistung",
    (series("Leistung", [target(em.PV_W, "PV"), target(em.LOAD_W, "Verbrauch"), target(em.GRID_W, "Netz"),
                         target(em.BATTERY_W, "Batterie"), target(em.UNACCOUNTED_W, "Nicht erfasst")],
            "watt", colors=COLORS, legend_calcs=["mean", "max"],
            description="Nicht erfasst: Erzeugung, die der Wechselrichter nicht sieht, etwa ein zweiter "
                        "Wechselrichter. Solange sie läuft, ist der Verbrauch unbekannt."), 24, 10),
    (series("Woher der Verbrauch kommt", [
        target(f"{em.LOAD_W} - {em.IMPORT_W} - {em.DISCHARGE_W}", "Eigenverbrauch"),
        target(em.DISCHARGE_W, "Entladen"),
        target(em.IMPORT_W, "Bezug")], "watt", stack=True, fill=60, colors=COLORS, minimum=0), 12, 9),
    (series("Wohin die PV geht", [
        target(f"{em.PV_W} - {em.EXPORT_W} - {em.CHARGE_W}", "Eigenverbrauch"),
        target(em.CHARGE_W, "Laden"),
        target(em.EXPORT_W, "Einspeisung")], "watt", stack=True, fill=60, colors=COLORS, minimum=0), 12, 9),
    (series("Autarkie und Eigenverbrauch, gleitend 1h", [
        target(f"clamp(1 - avg_over_time({em.IMPORT_KNOWN_LOAD_W}[1h:]) / avg_over_time({em.LOAD_W}[1h:]), 0, 1)",
               "Autarkie"),
        target(f"clamp(1 - avg_over_time({em.EXPORT_KNOWN_PV_W}[1h:]) / avg_over_time({em.PV_W}[1h:]), 0, 1)",
               "Eigenverbrauch")],
            "percentunit", minimum=0, maximum=1), 12, 8),
    (series("Grundlast", [target(f"quantile_over_time(0.05, {em.LOAD_W}[24h])", "Grundlast")],
            "watt", colors={"Grundlast": "red"}, time_from="30d",
            description="5%-Quantil der letzten 24h: was das Haus zieht, wenn nichts läuft."), 12, 8),
)

history = section(
    "Verlauf",
    (period_bars("Energie pro Tag", "day", "kwh", ["pv_kwh", "load_kwh", "import_kwh", "export_kwh"], 1,
                 f"Die letzten {DAYS_SHOWN} Tage, lokale Tage."), 24, 9),
    (period_bars("Energie pro Monat", "month", "kwh", ["pv_kwh", "load_kwh", "import_kwh", "export_kwh"], 0,
                 f"Die letzten {MONTHS_SHOWN} Monate."), 12, 9),
    (period_bars("Kosten pro Monat", "month", "eur",
                 ["electricity_eur", "gas_eur", "water_eur", "base_fees_eur", "feed_in_eur"], 0,
                 f"Die letzten {MONTHS_SHOWN} Monate. Einspeisevergütung negativ.", negative=("feed_in",)), 12, 9),
    (series("Wechselrichter gesamt", [target("fronius_inverter_energy_total_wh / 1000", "Gesamt")],
            "kwatth", decimals=0, time_from="1y"), 12, 7),
    (series("Zähler gesamt", [target(f"{em.IMPORT_WH} / 1000", "Bezug"), target(f"{em.EXPORT_WH} / 1000", "Einspeisung")],
            "kwatth", decimals=0, colors=COLORS, time_from="1y"), 12, 7),
)

meters = section(
    "Gas und Wasser",
    (stat("Gaszähler", [target(em.GAS_M3, instant=True)], "m3", 3, "orange"), 4, 4),
    (stat("Wasserzähler", [target(em.WATER_M3, instant=True)], "m3", 3, "blue"), 4, 4),
    (stat("Gas abgelesen vor", [target(reading_age("gas"), instant=True)], "s", 0,
          steps=[(None, "green"), (em.READING_STALE_S, "orange"), (em.READING_OVERDUE_S, "red")],
          description="Seit dem letzten übernommenen Stand; orange nach 36h."), 4, 4),
    (stat("Wasser abgelesen vor", [target(reading_age("water"), instant=True)], "s", 0,
          steps=[(None, "green"), (em.READING_STALE_S, "orange"), (em.READING_OVERDUE_S, "red")]), 4, 4),
    (stat("Gas, letzte 7 Tage", [target(em.meter_rise(em.GAS_M3, em.window_from_seconds(7 * em.SECONDS_PER_DAY)),
                                        instant=True)], "m3", 2, "orange"), 4, 4),
    (stat("Wasser, letzte 7 Tage", [target(em.meter_rise(em.WATER_M3, em.window_from_seconds(7 * em.SECONDS_PER_DAY)),
                                           instant=True)], "m3", 2, "blue"), 4, 4),
    (period_bars("Gas pro Tag", "day", "m3", ["gas_m3"], 2, f"Die letzten {DAYS_SHOWN} Tage, lokale Tage."), 12, 8),
    (period_bars("Wasser pro Tag", "day", "m3", ["water_m3"], 2, f"Die letzten {DAYS_SHOWN} Tage, lokale Tage."),
     12, 8),
)

battery = section(
    "Batterie",
    (series("Ladestand", [target(em.SOC_RATIO, "Ladestand")], "percentunit", minimum=0, maximum=1,
            colors={"Ladestand": "green"}), 12, 8),
    (series("Leistung", [target(em.BATTERY_W, "Batterie")], "watt", colors=COLORS,
            description="Positiv ist Entladen."), 12, 8),
    (series("Zelltemperatur", [target("fronius_battery_temperature_celsius", "Zellen")], "celsius"), 8, 7),
    (series("DC-Strom", [target("fronius_battery_current_amperes", "Strom")], "amp"), 8, 7),
    (stat("Vollzyklen im Zeitraum", [target(f"({ENERGY['discharge_kwh']}) / (max(fronius_battery_capacity_wh) / 1000)",
                                            instant=True)],
          "short", 2, "green", description="Entladene Energie geteilt durch Kapazität."), 4, 7),
    (stat("Kapazität", [target("fronius_battery_capacity_wh / 1000", instant=True)], "kwatth", 1, "green"), 4, 7),
)

grid_meter = section(
    "Netzzähler",
    (series("Leistung je Phase", [target("fronius_meter_power_watts", "L{{phase}}")], "watt",
            legend_calcs=["mean", "max"], description="Positiv ist Bezug."), 12, 8),
    (series("Spannung", [target("fronius_meter_voltage_volts", "L{{phase}}")], "volt", legend_calcs=["min", "max"]),
     12, 8),
    (series("Strom", [target("fronius_meter_current_amperes", "L{{phase}}")], "amp", legend_calcs=["mean", "max"]), 8, 8),
    (series("Leistungsfaktor", [target("fronius_meter_power_factor", "L{{phase}}")], "short"), 8, 8),
    (series("Blindleistung", [target("fronius_meter_reactive_power_var", "L{{phase}}")], "short"), 8, 8),
    (series("Außenleiterspannung", [target("fronius_meter_voltage_phase_to_phase_volts", "L{{phases}}")], "volt"),
     12, 7),
    (series("Netzfrequenz", [target("fronius_meter_frequency_hertz", "Netz")], "hertz", decimals=2), 12, 7),
    (series("Schieflast", [target("max(fronius_meter_power_watts) - min(fronius_meter_power_watts)", "Max - Min")],
            "watt", description="Abstand zwischen der am stärksten und der am schwächsten belasteten Phase."), 24, 7),
)

inverter = section(
    "Wechselrichter",
    (series("AC-Leistung", [target("fronius_inverter_ac_watts", "AC")], "watt"), 8, 7),
    (series("DC-Eingang", [target("fronius_inverter_dc_volts", "Spannung"), target("fronius_inverter_dc_amperes", "Strom")],
            "short"), 8, 7),
    (stat("Statuscode", [target("fronius_inverter_status_code", instant=True)], "none", 0, "blue"), 4, 7),
    (stat("Fehlercode", [target("fronius_inverter_error_code", instant=True)], "none", 0,
          steps=[(None, "green"), (1, "red")]), 4, 7),
    (state_timeline("Solar API erreichbar", [target("fronius_up", "{{endpoint}}")], {"0": "weg", "1": "da"},
                    [(None, "red"), (1, "green")]), 16, 6),
    (stat("Zählerposition", [target("fronius_site_info", "{{meter_location}}", instant=True)], "none",
          text_mode="name", description="Wo der Smart Meter sitzt (grid oder load); bei load rechnet Fronius "
                                        "den Netzbezug, nicht der Zähler."), 8, 6),
)

board = dashboard("Energie", "energy", [now, energy, costs, power, history, meters, battery, grid_meter, inverter],
                  time_from=TODAY[0], time_to=TODAY[1], tags=("energie", "haus"))

if __name__ == "__main__":
    dashboard_write(board, sys.argv[1])
