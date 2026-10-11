"""The boundary energy_model's users fetch through, faked: urlopen's answers and energy-charts' price api.

Imported by the tests of 104-internal-terminal's energy-sync and 105-internal-grafana's spot-price; import it after
setting ENERGY_SPOT_API, which energy_model reads at import.
"""
import datetime
import io
import json
import urllib.parse
from zoneinfo import ZoneInfo

import energy_model as em

BERLIN = ZoneInfo("Europe/Berlin")


def local_s(year, month, day, hour=0, minute=0):
    return int(datetime.datetime(year, month, day, hour, minute, tzinfo=BERLIN).timestamp())


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def json_response(body):
    return Response(json.dumps(body).encode())


class FakeSpot:
    """energy-charts' price api: quarter hours of the asked local days, priced by the hour of day; counts calls."""

    def __init__(self, fail=False):
        self.calls, self.fail = 0, fail

    def __call__(self, url, timeout):
        self.calls += 1
        if self.fail:
            raise TimeoutError("timed out")
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        first = datetime.date.fromisoformat(query["start"][0])
        last = datetime.date.fromisoformat(query["end"][0])
        start, _ = em.local_day_bounds(first)
        _, end = em.local_day_bounds(last)
        times = list(range(start, end, 900))
        # EUR per MWh: cheap at night, dearest at 18:00
        prices = [50.0 + datetime.datetime.fromtimestamp(t, BERLIN).hour * 10.0 for t in times]
        return json_response({"unix_seconds": times, "price": prices})
