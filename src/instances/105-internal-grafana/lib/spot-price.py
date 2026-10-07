"""Day-ahead spot price as node-exporter textfile metrics.

Usage: spot-price.py <cache.json> <out.prom>
Env:   SPOT_API (optional, the energy-charts price api)

Prices are wholesale EPEX slots for energy_model.SPOT_ZONE from energy-charts.info (CC BY 4.0, Bundesnetzagentur |
SMARD.de), without grid fees, levies or VAT. They are published once a day, so they come from <cache.json>, which
is fetched only when a published day is missing (energy_model.spot_cache_refresh): a few calls a day, not one per
run. "Today" is the house's local day, 23 or 25 hours on a dst change. No current slot removes <out.prom>: no
data, never a stale price.
"""
import os
import sys
import time
import urllib.request

import energy_model as em
import feed_io

SPOT_API = os.environ.get("SPOT_API", em.SPOT_API)


def prom_render(current, stats):
    low, mean, high = stats
    return "\n".join([
        "# HELP energy_spot_price_eur_per_kwh Day-ahead wholesale price of the current slot.",
        "# TYPE energy_spot_price_eur_per_kwh gauge",
        f'energy_spot_price_eur_per_kwh{{zone="{em.SPOT_ZONE}"}} {current!r}',
        "# HELP energy_spot_price_today_eur_per_kwh Day-ahead wholesale price over the local day.",
        "# TYPE energy_spot_price_today_eur_per_kwh gauge",
        f'energy_spot_price_today_eur_per_kwh{{zone="{em.SPOT_ZONE}",stat="min"}} {low!r}',
        f'energy_spot_price_today_eur_per_kwh{{zone="{em.SPOT_ZONE}",stat="avg"}} {mean!r}',
        f'energy_spot_price_today_eur_per_kwh{{zone="{em.SPOT_ZONE}",stat="max"}} {high!r}',
    ]) + "\n"


def run(cache_path, out_path, now_s, urlopen=urllib.request.urlopen):
    cache = em.spot_cache_refresh(feed_io.file_json_load(cache_path), now_s,
                                  lambda first, last: em.spot_fetch(urlopen, SPOT_API, em.SPOT_ZONE, first, last))
    feed_io.file_write_atomic(cache_path, feed_io.json_dumps(cache))
    slots = em.spot_cache_slots(cache)
    current = em.spot_current(slots, now_s)
    stats = em.spot_day_stats(slots, *em.local_day_bounds(em.local_today(now_s)))
    if current is None or stats is None:
        if os.path.exists(out_path):
            os.remove(out_path)
        feed_io.log("no spot price for now")
        return 1
    feed_io.file_write_atomic(out_path, prom_render(current, stats))
    feed_io.log(f"spot {current * 100:.2f} ct/kWh, today {stats[0] * 100:.2f} to {stats[2] * 100:.2f}")
    return 0


def main():
    if len(sys.argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    return run(sys.argv[1], sys.argv[2], time.time())


if __name__ == "__main__":
    sys.exit(main())
