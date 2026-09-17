"""Merge remote ICS feeds into one calendar and render a TRMNL payload.

Reads a sources file of "NAME|URL" lines, fetches each feed, and writes two
files into the output directory:

  merged.ics   every event from every source, for clients to subscribe to
  trmnl.json   the next two weeks of events plus Kraken prices, for a TRMNL
               private plugin to poll

A source that fails to fetch is skipped with a warning rather than taking the
whole run down, so one broken feed cannot empty a calendar that devices are
already subscribed to.
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone

import recurring_ical_events
from icalendar import Calendar

TIMEOUT = 30
HORIZON_DAYS = 14
USER_AGENT = "homelab-calendar-sync/1"
KRAKEN_API = "https://api.kraken.com"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def read_sources(path):
    """Parse NAME|URL lines, ignoring blanks and comments."""
    sources = []
    if not os.path.exists(path):
        log(f"sources file {path} missing")
        return sources
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "|" not in line:
                log(f"ignoring malformed source line: {line!r}")
                continue
            name, url = line.split("|", 1)
            name, url = name.strip(), url.strip()
            if name and url:
                sources.append((name, url))
    return sources


def fetch(url, headers=None, data=None):
    request = urllib.request.Request(url, data=data)
    request.add_header("User-Agent", USER_AGENT)
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read()


def load_calendars(sources):
    """Fetch and parse every source. Returns [(name, Calendar)]."""
    calendars = []
    for name, url in sources:
        try:
            calendars.append((name, Calendar.from_ical(fetch(url))))
        except Exception as err:  # noqa: BLE001 - one bad feed must not stop the rest
            log(f"source {name}: {err}")
    return calendars


def merge(calendars):
    """Build one calendar holding every component from every source."""
    merged = Calendar()
    merged.add("prodid", "-//homelab//calendar-sync//EN")
    merged.add("version", "2.0")
    merged.add("x-wr-calname", "Homelab")

    seen_timezones = set()
    for name, calendar in calendars:
        for component in calendar.walk():
            kind = component.name
            if kind == "VTIMEZONE":
                tzid = str(component.get("tzid", ""))
                if tzid in seen_timezones:
                    continue
                seen_timezones.add(tzid)
                merged.add_component(component)
            elif kind in ("VEVENT", "VTODO"):
                # Distinct sources can reuse a UID; without a prefix a client
                # would treat those as the same event and drop one.
                uid = str(component.get("uid", ""))
                component["UID"] = f"{name}-{uid}"
                component["CATEGORIES"] = name
                merged.add_component(component)
    return merged


def to_iso(value):
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def upcoming(calendars, horizon_days):
    """Expand recurrences and return the events in the next horizon_days."""
    now = datetime.now(timezone.utc)
    end = now + timedelta(days=horizon_days)
    events = []

    for name, calendar in calendars:
        try:
            occurrences = recurring_ical_events.of(calendar).between(now, end)
        except Exception as err:  # noqa: BLE001 - keep the other sources
            log(f"expanding {name}: {err}")
            continue

        for event in occurrences:
            start = event.get("DTSTART")
            stop = event.get("DTEND")
            start_value = start.dt if start is not None else None
            # An all-day event carries a date rather than a datetime.
            all_day = isinstance(start_value, date) and not isinstance(start_value, datetime)
            events.append({
                "source": name,
                "summary": str(event.get("SUMMARY", "")),
                "location": str(event.get("LOCATION", "")),
                "start": to_iso(start_value) if start_value is not None else None,
                "end": to_iso(stop.dt) if stop is not None else None,
                "all_day": all_day,
            })

    events.sort(key=lambda e: (e["start"] is None, e["start"] or ""))
    return events


def kraken_ticker(pairs):
    if not pairs:
        return {}
    try:
        url = f"{KRAKEN_API}/0/public/Ticker?pair={urllib.parse.quote(','.join(pairs))}"
        payload = json.loads(fetch(url))
    except Exception as err:  # noqa: BLE001 - prices are optional decoration
        log(f"kraken ticker: {err}")
        return {}

    if payload.get("error"):
        log(f"kraken ticker: {payload['error']}")
        return {}

    ticker = {}
    for pair, values in payload.get("result", {}).items():
        try:
            last = float(values["c"][0])
            opening = float(values["o"])
            change = ((last - opening) / opening * 100) if opening else 0.0
            ticker[pair] = {"last": round(last, 2), "change_pct": round(change, 2)}
        except (KeyError, ValueError, TypeError) as err:
            log(f"kraken ticker {pair}: {err}")
    return ticker


def kraken_balance(key, secret):
    """Call the private Balance endpoint, which needs an HMAC-SHA512 signature."""
    path = "/0/private/Balance"
    nonce = str(int(time.time() * 1000))
    body = urllib.parse.urlencode({"nonce": nonce}).encode()

    digest = hashlib.sha256(nonce.encode() + body).digest()
    signature = hmac.new(base64.b64decode(secret), path.encode() + digest, hashlib.sha512)
    headers = {
        "API-Key": key,
        "API-Sign": base64.b64encode(signature.digest()).decode(),
        "Content-Type": "application/x-www-form-urlencoded",
    }

    try:
        payload = json.loads(fetch(KRAKEN_API + path, headers=headers, data=body))
    except Exception as err:  # noqa: BLE001 - balances are optional
        log(f"kraken balance: {err}")
        return {}

    if payload.get("error"):
        log(f"kraken balance: {payload['error']}")
        return {}

    # Kraken reports every asset it has ever held, most of them at zero.
    return {
        asset: float(amount)
        for asset, amount in payload.get("result", {}).items()
        if float(amount) != 0
    }


def read_secret(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        value = handle.read().strip()
    return value or None


def write_atomic(path, data):
    """Write through a temporary file so a reader never sees a half-written feed."""
    tmp = f"{path}.tmp"
    mode = "wb" if isinstance(data, bytes) else "w"
    with open(tmp, mode) as handle:
        handle.write(data)
    os.replace(tmp, path)


def main():
    sources_file = os.environ["CALENDAR_SOURCES"]
    out_dir = os.environ["CALENDAR_OUT"]
    pairs = [p for p in os.environ.get("KRAKEN_PAIRS", "").split(",") if p.strip()]

    os.makedirs(out_dir, exist_ok=True)

    sources = read_sources(sources_file)
    if not sources:
        log("no calendar sources configured")

    calendars = load_calendars(sources)
    if sources and not calendars:
        # Every source failed. Leaving the previous output in place beats
        # replacing a working calendar with an empty one.
        log("every source failed, keeping previous output")
        return 1

    write_atomic(os.path.join(out_dir, "merged.ics"), merge(calendars).to_ical())

    key = read_secret(os.environ.get("KRAKEN_KEY_FILE"))
    secret = read_secret(os.environ.get("KRAKEN_SECRET_FILE"))

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "sources": [name for name, _ in sources],
        "events": upcoming(calendars, HORIZON_DAYS),
        "kraken": {
            "ticker": kraken_ticker(pairs),
            "balance": kraken_balance(key, secret) if key and secret else {},
        },
    }
    write_atomic(os.path.join(out_dir, "trmnl.json"), json.dumps(payload, indent=2))

    log(f"wrote {len(payload['events'])} events from {len(calendars)} sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
