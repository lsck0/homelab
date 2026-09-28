"""Day-ahead spot price for DE-LU as node-exporter textfile metrics.

Usage: spot-price.py <out.prom>

Prices are wholesale EPEX quarter hours from energy-charts.info (CC BY 4.0,
Bundesnetzagentur | SMARD.de), without grid fees, levies or VAT. A missing
answer removes the file: no data, never a stale price.
"""
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

API = os.environ.get("SPOT_API", "https://api.energy-charts.info/price")
ZONE = os.environ.get("SPOT_ZONE", "DE-LU")
TIMEOUT_S = 20
EUR_PER_MWH_TO_KWH = 1 / 1000


def spot_fetch(day_start, day_end):
    """(unix_seconds, eur_per_kwh) pairs, sorted, or None."""
    query = urllib.parse.urlencode({"bzn": ZONE, "start": day_start.isoformat(), "end": day_end.isoformat()})
    try:
        with urllib.request.urlopen(f"{API}?{query}", timeout=TIMEOUT_S) as r:
            body = json.load(r)
    except (urllib.error.URLError, socket.timeout, ValueError) as e:
        print(f"spot price fetch failed: {e}", file=sys.stderr)
        return None
    times, prices = body.get("unix_seconds") or [], body.get("price") or []
    if len(times) != len(prices):
        print(f"spot price: {len(times)} times but {len(prices)} prices", file=sys.stderr)
        return None
    return sorted((t, p * EUR_PER_MWH_TO_KWH) for t, p in zip(times, prices) if p is not None)


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    out = sys.argv[1]

    today = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
    slots = spot_fetch(today.date(), (today + timedelta(days=1)).date())
    now = time.time()
    # the slot that started last, today's only
    current = [p for t, p in slots or [] if t <= now and t >= today.timestamp()]
    if not current:
        if os.path.exists(out):
            os.remove(out)
        print("no spot price for now", file=sys.stderr)
        return 1

    day = [p for t, p in slots if today.timestamp() <= t < (today + timedelta(days=1)).timestamp()]
    lines = [
        "# HELP energy_spot_price_eur_per_kwh Day-ahead wholesale price of the current quarter hour.",
        "# TYPE energy_spot_price_eur_per_kwh gauge",
        f'energy_spot_price_eur_per_kwh{{zone="{ZONE}"}} {current[-1]!r}',
        "# HELP energy_spot_price_today_eur_per_kwh Day-ahead wholesale price over today.",
        "# TYPE energy_spot_price_today_eur_per_kwh gauge",
        f'energy_spot_price_today_eur_per_kwh{{zone="{ZONE}",stat="min"}} {min(day)!r}',
        f'energy_spot_price_today_eur_per_kwh{{zone="{ZONE}",stat="avg"}} {sum(day) / len(day)!r}',
        f'energy_spot_price_today_eur_per_kwh{{zone="{ZONE}",stat="max"}} {max(day)!r}',
    ]
    with open(out + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(out + ".tmp", out)
    print(f"spot {current[-1] * 100:.2f} ct/kWh, today {min(day) * 100:.2f} to {max(day) * 100:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
