"""The Grafana boards 105-internal-grafana.nix provisions, as built: layout, queries and the metrics they read.

Usage: dashboards_test.py <out dir> <feeds dir> <spot-price.py> <board.json>...   (<feeds dir>: 104's tests/feeds.nix $out)

Checks every board: panels inside the 24 columns and never overlapping, refIds unique within a panel. Writes
<out dir>/queries.json, every PromQL query as a recording rule with Grafana's macros filled in, which
tests/dashboards.nix hands to `promtool check rules`, the offline PromQL parser. On the energy board, every metric
of the house's families (fronius_, hass_, energy_, homelab_energy_) must be one a producer in this repo writes:
the inverter exporter (its exposition of every fixture in 104-internal-terminal/tests/feeds_test.py), the spot price export,
energy-sync's period gauges, the home assistant inputs.
"""
import json
import os
import re
import sys

OUT, FEEDS, SPOT_PRICE, BOARDS = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
GRID_COLUMNS = 24
# Grafana's macros and the boards' variables, as a query would see them
MACROS = {"$__range_s": "3600", "$__range": "1h", "$__rate_interval": "1m", "$__interval": "1m", "$vm": ".*",
          "$service": ".*"}
FAMILIES = re.compile(r"\b(fronius_[a-z_]+|hass_[a-z_]+|energy_spot_[a-z_]+|homelab_energy_[a-z_]+)\b")


def macros_fill(expr):
    for macro in sorted(MACROS, key=len, reverse=True):
        expr = expr.replace(macro, MACROS[macro])
    return expr


def producers():
    """Every metric name of the house's families something in this repo writes."""
    import energy_model as em
    names = set()
    for exposition in (f for f in os.listdir(FEEDS) if f.startswith("fronius-")):
        with open(os.path.join(FEEDS, exposition)) as handle:
            names |= {line.split("{")[0].split(" ")[0] for line in handle if line.strip() and not line.startswith("#")}
    with open(SPOT_PRICE) as handle:
        names |= set(re.findall(r"(energy_spot_price_[a-z_]+)", handle.read()))
    names |= {em.period_metric(period, unit) for period in em.PERIOD_LABEL_FORMATS
              for unit, _, _ in em.PERIOD_TERMS.values()}
    names |= {m[key] for m in em.METERS.values() for key in ("readingMetric", "readAtMetric")}
    names.add(em.INPUTS["helperMetricPrefix"])
    return names


def overlaps(a, b):
    return (a["x"] < b["x"] + b["w"] and b["x"] < a["x"] + a["w"]
            and a["y"] < b["y"] + b["h"] and b["y"] < a["y"] + a["h"])


failures, rules = [], []
for path in BOARDS:
    with open(path) as handle:
        board = json.load(handle)
    name = board["uid"]
    panels = board["panels"]
    for p in panels:
        pos = p["gridPos"]
        if pos["x"] < 0 or pos["w"] <= 0 or pos["x"] + pos["w"] > GRID_COLUMNS:
            failures.append(f"{name}: {p.get('title')} outside the grid: {pos}")
        refs = [t["refId"] for t in p.get("targets", [])]
        if len(refs) != len(set(refs)):
            failures.append(f"{name}: {p.get('title')} repeats a refId: {refs}")
        for t in p.get("targets", []):
            if (t.get("datasource") or p.get("datasource") or {}).get("type") == "prometheus":
                rules.append({"record": f"check:{name.replace('-', '_')}:{len(rules)}", "expr": macros_fill(t["expr"])})
    for i, a in enumerate(panels):
        for b in panels[i + 1:]:
            if overlaps(a["gridPos"], b["gridPos"]):
                failures.append(f"{name}: {a.get('title')} overlaps {b.get('title')}")
    if name == "energy":
        known = producers()
        for p in panels:
            for t in p.get("targets", []):
                for metric in set(FAMILIES.findall(t.get("expr", ""))) - known:
                    failures.append(f"energy: {p['title']} reads {metric}, which nothing in the repo writes")

with open(os.path.join(OUT, "queries.json"), "w") as handle:
    json.dump({"groups": [{"name": "dashboards", "rules": rules}]}, handle, indent=2)
for failure in failures:
    print(failure, file=sys.stderr)
print(f"{len(BOARDS)} boards, {len(rules)} prometheus queries")
sys.exit(1 if failures else 0)
