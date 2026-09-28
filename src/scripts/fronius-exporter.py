"""Prometheus exporter for a Fronius inverter's local Solar API (v1).

Polls only when scraped: one scrape reads power flow, meter, battery and
inverter in four requests and answers with every value as a gauge.

Usage: fronius-exporter.py
Env:   FRONIUS_HOST (inverter address), FRONIUS_LISTEN (host:port)

Signs follow the site, not Fronius: load and pv are positive, grid is
positive when importing, battery is positive when discharging.
"""
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("FRONIUS_HOST", "192.168.178.46")
LISTEN = os.environ.get("FRONIUS_LISTEN", "127.0.0.1:9118")
# the datamanager answers in ~200ms; a hung call must not outlive the 10s scrape
TIMEOUT_S = 3

ENDPOINTS = {
    "powerflow": "GetPowerFlowRealtimeData.fcgi",
    "meter": "GetMeterRealtimeData.cgi?Scope=System",
    "storage": "GetStorageRealtimeData.cgi?Scope=System",
    "inverter": "GetInverterRealtimeData.cgi?Scope=Device&DeviceId=1&DataCollection=CommonInverterData",
}

# meter field -> (metric, help), one series per phase
METER_PHASE = {
    "PowerReal_P_Phase_{}": ("fronius_meter_power_watts", "Real power per phase at the grid meter, import positive."),
    "PowerApparent_S_Phase_{}": ("fronius_meter_apparent_power_va", "Apparent power per phase."),
    "PowerReactive_Q_Phase_{}": ("fronius_meter_reactive_power_var", "Reactive power per phase."),
    "PowerFactor_Phase_{}": ("fronius_meter_power_factor", "Power factor per phase."),
    "Voltage_AC_Phase_{}": ("fronius_meter_voltage_volts", "Phase to neutral voltage."),
    "Current_AC_Phase_{}": ("fronius_meter_current_amperes", "Current per phase."),
}
PHASES = ("1", "2", "3")
PHASE_PAIRS = ("12", "23", "31")

# meter counters are lifetime watt-hours
METER_TOTAL = {
    "EnergyReal_WAC_Plus_Absolute": ("fronius_meter_import_wh", "Energy drawn from the grid, lifetime."),
    "EnergyReal_WAC_Minus_Absolute": ("fronius_meter_export_wh", "Energy fed into the grid, lifetime."),
}


def fetch(path):
    """Body.Data of one Solar API call, or None."""
    url = f"http://{HOST}/solar_api/v1/{path}"
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT_S) as r:
            body = json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"{path}: {e}", file=sys.stderr)
        return None
    status = body.get("Head", {}).get("Status", {})
    if status.get("Code") != 0:
        print(f"{path}: status {status.get('Code')} {status.get('Reason')}", file=sys.stderr)
        return None
    return body.get("Body", {}).get("Data")


def number(value):
    """Float, or None for the nulls Fronius sends at night."""
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


class Metrics:
    """Collects samples grouped by metric, rendered once."""

    def __init__(self):
        self.help = {}
        self.samples = {}

    def add(self, name, help_text, value, labels=None):
        v = number(value)
        if v is None:
            return
        self.help.setdefault(name, help_text)
        label = ""
        if labels:
            label = "{" + ",".join(f'{key}="{val}"' for key, val in sorted(labels.items())) + "}"
        self.samples.setdefault(name, []).append(f"{name}{label} {v!r}")

    def render(self):
        out = []
        for name, lines in self.samples.items():
            out.append(f"# HELP {name} {self.help[name]}")
            out.append(f"# TYPE {name} gauge")
            out.extend(lines)
        return "\n".join(out) + "\n"


def collect_powerflow(m, data):
    site = data.get("Site", {})
    # pv is null at night: no production, not unknown
    m.add("fronius_pv_watts", "PV production.", number(site.get("P_PV")) or 0.0)
    m.add("fronius_grid_watts", "Grid power, import positive.", site.get("P_Grid"))
    load = number(site.get("P_Load"))
    m.add("fronius_load_watts", "House consumption.", -load if load is not None else None)
    m.add("fronius_battery_watts", "Battery power, discharge positive.", number(site.get("P_Akku")) or 0.0)
    m.add("fronius_autonomy_ratio", "Share of consumption not drawn from the grid.",
          (number(site.get("rel_Autonomy")) or 0.0) / 100)
    self_use = number(site.get("rel_SelfConsumption"))
    m.add("fronius_self_consumption_ratio", "Share of production used on site.",
          self_use / 100 if self_use is not None else None)
    for key, name in (("E_Day", "day"), ("E_Year", "year"), ("E_Total", "total")):
        m.add(f"fronius_inverter_energy_{name}_wh", f"Inverter AC output, current {name}.", site.get(key))
    for inv in data.get("Inverters", {}).values():
        m.add("fronius_battery_soc_ratio", "Battery state of charge.", (number(inv.get("SOC")) or 0.0) / 100)


def collect_meter(m, data):
    for meter in data.values():
        for field, (name, help_text) in METER_PHASE.items():
            for phase in PHASES:
                m.add(name, help_text, meter.get(field.format(phase)), {"phase": phase})
        for pair in PHASE_PAIRS:
            m.add("fronius_meter_voltage_phase_to_phase_volts", "Phase to phase voltage.",
                  meter.get(f"Voltage_AC_PhaseToPhase_{pair}"), {"phases": pair})
        m.add("fronius_meter_frequency_hertz", "Grid frequency.", meter.get("Frequency_Phase_Average"))
        for field, (name, help_text) in METER_TOTAL.items():
            m.add(name, help_text, meter.get(field))


def collect_storage(m, data):
    for battery in data.values():
        c = battery.get("Controller", {})
        m.add("fronius_battery_temperature_celsius", "Battery cell temperature.", c.get("Temperature_Cell"))
        m.add("fronius_battery_current_amperes", "Battery DC current.", c.get("Current_DC"))
        m.add("fronius_battery_capacity_wh", "Usable battery capacity.", c.get("Capacity_Maximum"))
        m.add("fronius_battery_design_capacity_wh", "Battery design capacity.", c.get("DesignedCapacity"))


def collect_inverter(m, data):
    def value(key):
        return (data.get(key) or {}).get("Value")

    status = data.get("DeviceStatus", {})
    m.add("fronius_inverter_status_code", "Inverter device status code.", status.get("StatusCode"))
    m.add("fronius_inverter_error_code", "Inverter error, 0 is none.", status.get("ErrorCode"))
    m.add("fronius_inverter_dc_volts", "DC input voltage.", value("UDC"))
    m.add("fronius_inverter_dc_amperes", "DC input current.", value("IDC"))
    m.add("fronius_inverter_ac_watts", "AC output power.", value("PAC") or 0.0)


COLLECTORS = {
    "powerflow": collect_powerflow,
    "meter": collect_meter,
    "storage": collect_storage,
    "inverter": collect_inverter,
}


def scrape():
    m = Metrics()
    for key, path in ENDPOINTS.items():
        data = fetch(path)
        m.add("fronius_up", "Whether the endpoint answered.", 0.0 if data is None else 1.0, {"endpoint": key})
        if data is not None:
            COLLECTORS[key](m, data)
    return m.render()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path != "/metrics":
            self.send_error(404)
            return
        body = scrape().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    addr, _, port = LISTEN.rpartition(":")
    ThreadingHTTPServer((addr, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
