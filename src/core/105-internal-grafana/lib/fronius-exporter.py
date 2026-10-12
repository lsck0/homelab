"""Prometheus exporter for a Fronius inverter's local Solar API (v1).

Polls only when scraped: one scrape reads power flow, meter, battery and inverter in four concurrent requests
under one deadline, the scrape timeout Prometheus sends minus SCRAPE_MARGIN_S, and answers with every value it got
as a gauge. An endpoint that misses the deadline reports fronius_up{endpoint} 0; the others still answer.

Usage: fronius-exporter.py
Env:   FRONIUS_HOST (inverter address), FRONIUS_LISTEN (host:port)

Signs follow the site, not Fronius: load and pv are positive, grid is positive when importing, battery is positive
when discharging. A value Fronius does not send is absent, never 0: a battery that went offline must not read as
an empty battery at rest. The one exception is pv at night, which Fronius sends as null and is a real 0.

Load: Fronius computes P_Load = -(P_Grid + P_PV + P_Akku), so a generator it cannot see (a second inverter,
AC-coupled pv) makes the house a net source and P_Load positive. Then the real load is unknown: it is left out and
the surplus is exported as fronius_unaccounted_watts. fronius_site_info{meter_location} says where the smart
meter sits, which decides whether Fronius measures the grid or computes it.
"""
import concurrent.futures
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- constants ----------------------------------------------------------------------------------

HOST = os.environ.get("FRONIUS_HOST", "")
LISTEN = os.environ.get("FRONIUS_LISTEN", "127.0.0.1:9118")
# prometheus' default when a client sends no header, the lab's scrape_timeout too
SCRAPE_TIMEOUT_DEFAULT_S = 10.0
# rendering and the answer itself must fit after the last fetch gives up
SCRAPE_MARGIN_S = 0.5
SCRAPE_TIMEOUT_HEADER = "X-Prometheus-Scrape-Timeout-Seconds"
PERCENT = 100

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


# ---- solar api ----------------------------------------------------------------------------------

def fetch(host, path, timeout_s):
    """Body.Data of one Solar API call, or None."""
    url = f"http://{host}/solar_api/v1/{path}"
    try:
        with urllib.request.urlopen(url, timeout=timeout_s) as r:
            body = json.load(r)
    except (urllib.error.URLError, socket.timeout, TimeoutError, ValueError, OSError) as e:
        print(f"{path}: {e}", file=sys.stderr)
        return None
    if not isinstance(body, dict):
        return None
    status = body.get("Head", {}).get("Status", {})
    if status.get("Code") != 0:
        print(f"{path}: status {status.get('Code')} {status.get('Reason')}", file=sys.stderr)
        return None
    data = body.get("Body", {}).get("Data")
    return data if isinstance(data, dict) else None


def fetch_all(fetch_one, deadline_s):
    """endpoint -> Data or None, the four calls concurrent; a call still running at the deadline counts as None."""
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=len(ENDPOINTS))
    futures = {key: pool.submit(fetch_one, path, deadline_s) for key, path in ENDPOINTS.items()}
    concurrent.futures.wait(futures.values(), timeout=deadline_s)
    # a hung call keeps its thread until its own socket timeout, the same deadline; nothing waits for it
    pool.shutdown(wait=False, cancel_futures=True)
    return {key: f.result() if f.done() and not f.cancelled() else None for key, f in futures.items()}


def number(value):
    """Float, or None for a null, a bool or anything else that is not a number."""
    if isinstance(value, bool) or value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


# ---- exposition ---------------------------------------------------------------------------------

def label_escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class Metrics:
    """Samples grouped by metric, rendered once; a missing value adds nothing."""

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
            label = "{" + ",".join(f'{k}="{label_escape(val)}"' for k, val in sorted(labels.items())) + "}"
        self.samples.setdefault(name, []).append(f"{name}{label} {v!r}")

    def render(self):
        out = []
        for name, lines in self.samples.items():
            out.append(f"# HELP {name} {self.help[name]}")
            out.append(f"# TYPE {name} gauge")
            out.extend(lines)
        return "\n".join(out) + "\n"


def ratio(value):
    v = number(value)
    return v / PERCENT if v is not None else None


# ---- collectors ---------------------------------------------------------------------------------

def collect_powerflow(m, data):
    site = data.get("Site") or {}
    pv = number(site.get("P_PV"))
    # pv is null at night: no production, not unknown
    m.add("fronius_pv_watts", "PV production.", pv if pv is not None else 0.0)
    m.add("fronius_grid_watts", "Grid power, import positive.", site.get("P_Grid"))
    load = number(site.get("P_Load"))
    if load is not None and load > 0:
        m.add("fronius_unaccounted_watts", "Generation Fronius cannot see; the house load is unknown meanwhile.", load)
    elif load is not None:
        m.add("fronius_load_watts", "House consumption.", -load)
    m.add("fronius_battery_watts", "Battery power, discharge positive.", site.get("P_Akku"))
    m.add("fronius_autonomy_ratio", "Share of consumption not drawn from the grid.", ratio(site.get("rel_Autonomy")))
    m.add("fronius_self_consumption_ratio", "Share of production used on site.",
          ratio(site.get("rel_SelfConsumption")))
    if site.get("Meter_Location") is not None:
        m.add("fronius_site_info", "Where the smart meter sits: grid (measured) or load (grid computed).", 1.0,
              {"meter_location": site.get("Meter_Location")})
    for key, name in (("E_Day", "day"), ("E_Year", "year"), ("E_Total", "total")):
        m.add(f"fronius_inverter_energy_{name}_wh", f"Inverter AC output, current {name}.", site.get(key))
    for inverter in (data.get("Inverters") or {}).values():
        m.add("fronius_battery_soc_ratio", "Battery state of charge.", ratio(inverter.get("SOC")))


def collect_meter(m, data):
    for meter in data.values():
        if not isinstance(meter, dict):
            continue
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
        if not isinstance(battery, dict):
            continue
        c = battery.get("Controller") or {}
        m.add("fronius_battery_temperature_celsius", "Battery cell temperature.", c.get("Temperature_Cell"))
        m.add("fronius_battery_current_amperes", "Battery DC current.", c.get("Current_DC"))
        m.add("fronius_battery_capacity_wh", "Usable battery capacity.", c.get("Capacity_Maximum"))
        m.add("fronius_battery_design_capacity_wh", "Battery design capacity.", c.get("DesignedCapacity"))


def collect_inverter(m, data):
    def value(key):
        return (data.get(key) or {}).get("Value")

    status = data.get("DeviceStatus") or {}
    m.add("fronius_inverter_status_code", "Inverter device status code.", status.get("StatusCode"))
    m.add("fronius_inverter_error_code", "Inverter error, 0 is none.", status.get("ErrorCode"))
    m.add("fronius_inverter_dc_volts", "DC input voltage.", value("UDC"))
    m.add("fronius_inverter_dc_amperes", "DC input current.", value("IDC"))
    m.add("fronius_inverter_ac_watts", "AC output power.", value("PAC"))


COLLECTORS = {
    "powerflow": collect_powerflow,
    "meter": collect_meter,
    "storage": collect_storage,
    "inverter": collect_inverter,
}
assert COLLECTORS.keys() == ENDPOINTS.keys()


def scrape(fetch_one, deadline_s):
    """The exposition text of one scrape; fetch_one(path, timeout_s) -> Data or None."""
    m = Metrics()
    for key, data in fetch_all(fetch_one, deadline_s).items():
        m.add("fronius_up", "Whether the endpoint answered.", 0.0 if data is None else 1.0, {"endpoint": key})
        if data is not None:
            COLLECTORS[key](m, data)
    return m.render()


def scrape_deadline_s(header_value):
    """The time the fetches may take: the scrape timeout prometheus sends, minus the margin."""
    timeout_s = number(header_value)
    if timeout_s is None or timeout_s <= 0:
        timeout_s = SCRAPE_TIMEOUT_DEFAULT_S
    return max(SCRAPE_MARGIN_S, timeout_s - SCRAPE_MARGIN_S)


# ---- server -------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path != "/metrics":
            self.send_error(404)
            return
        deadline_s = scrape_deadline_s(self.headers.get(SCRAPE_TIMEOUT_HEADER))
        body = scrape(lambda path, timeout_s: fetch(HOST, path, timeout_s), deadline_s).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    if not HOST:
        print("FRONIUS_HOST is not set", file=sys.stderr)
        return 2
    addr, _, port = LISTEN.rpartition(":")
    ThreadingHTTPServer((addr, int(port)), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
