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
from zoneinfo import ZoneInfo

import recurring_ical_events
from icalendar import Calendar

TIMEOUT = 30
# How far ahead to look, and how many events to keep. A fixed short window is
# wrong for a sparse personal calendar: with a 14 day horizon the payload was
# empty whenever the next appointment happened to be a month out. Look far
# ahead instead and cap the count, so the screen always shows "what is next"
# regardless of how busy the calendar is.
HORIZON_DAYS = int(os.environ.get("CALENDAR_HORIZON_DAYS", "90"))
MAX_EVENTS = int(os.environ.get("CALENDAR_MAX_EVENTS", "12"))
# The week view is rendered in local time: a day column has to start at local
# midnight, not UTC midnight, or late-evening events land on the wrong day.
LOCAL_TZ = ZoneInfo(os.environ.get("CALENDAR_TZ", "Europe/Berlin"))
# Which weeks to publish, as offsets from the current one. The device cannot
# tell a plugin "show me last week", so each offset is served as its own static
# file and gets its own plugin instance in the playlist.
WEEK_OFFSETS = [int(o) for o in os.environ.get("CALENDAR_WEEK_OFFSETS", "-1,0,1").split(",")]
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


def uploaded_sources(upload_dir):
    """Every validated .ics pushed to the upload endpoint, as (name, file URL).

    A calendar whose owner blocks publishing has no URL to poll, so it is PUT
    here instead and picked up by filename. No entry in calendar-sources is
    needed: dropping work.ics in is enough to make "work" a source.
    """
    if not upload_dir or not os.path.isdir(upload_dir):
        return []
    found = []
    for entry in sorted(os.listdir(upload_dir)):
        if not entry.endswith(".ics"):
            continue
        path = os.path.join(upload_dir, entry)
        if os.path.getsize(path) == 0:
            continue
        found.append((entry[: -len(".ics")], "file://" + urllib.request.pathname2url(path)))
    return found


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
            events.append(event_row(name, event))

    events.sort(key=lambda e: (e["start"] is None, e["start"] or ""))
    return events[:MAX_EVENTS]


def event_row(name, event):
    """One event as the template consumes it."""
    start = event.get("DTSTART")
    stop = event.get("DTEND")
    start_value = start.dt if start is not None else None
    all_day = isinstance(start_value, date) and not isinstance(start_value, datetime)
    return {
        "source": name,
        "summary": str(event.get("SUMMARY", "")),
        "location": str(event.get("LOCATION", "")),
        "start": to_iso(start_value) if start_value is not None else None,
        "end": to_iso(stop.dt) if stop is not None else None,
        "all_day": all_day,
        # pre-rendered so the Liquid template does not have to parse a timestamp
        "time": "" if all_day or start_value is None
                else start_value.astimezone(LOCAL_TZ).strftime("%H:%M"),
    }


def local_day(value):
    """The local calendar day an event belongs in."""
    if isinstance(value, datetime):
        return value.astimezone(LOCAL_TZ).date()
    return value


def week(calendars, offset):
    """One Monday-to-Sunday grid, `offset` weeks from the current one."""
    today = datetime.now(LOCAL_TZ).date()
    monday = today - timedelta(days=today.weekday()) + timedelta(weeks=offset)
    sunday = monday + timedelta(days=6)

    start = datetime.combine(monday, datetime.min.time(), LOCAL_TZ)
    end = start + timedelta(days=7)

    by_day = {monday + timedelta(days=i): [] for i in range(7)}
    for name, calendar in calendars:
        try:
            occurrences = recurring_ical_events.of(calendar).between(start, end)
        except Exception as err:  # noqa: BLE001 - keep the other sources
            log(f"expanding {name} for week {offset:+d}: {err}")
            continue
        for event in occurrences:
            dtstart = event.get("DTSTART")
            if dtstart is None:
                continue
            day = local_day(dtstart.dt)
            if day in by_day:
                by_day[day].append(event_row(name, event))

    days = []
    for day in sorted(by_day):
        rows = sorted(by_day[day], key=lambda e: (not e["all_day"], e["time"]))
        days.append({
            "date": day.isoformat(),
            "day": day.day,
            "weekday": day.strftime("%a"),
            "is_today": day == today,
            "events": rows,
        })

    same_month = monday.strftime("%b") == sunday.strftime("%b")
    label = (f"{monday.day}–{sunday.day} {sunday.strftime('%b %Y')}" if same_month
             else f"{monday.day} {monday.strftime('%b')} – {sunday.day} {sunday.strftime('%b %Y')}")

    return {
        "offset": offset,
        "label": label,
        "week_number": monday.isocalendar().week,
        "is_current": offset == 0,
        "start": monday.isoformat(),
        "end": sunday.isoformat(),
        "total_events": sum(len(d["events"]) for d in days),
        "days": days,
    }


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

    sources = read_sources(sources_file) + uploaded_sources(os.environ.get("CALENDAR_UPLOAD_DIR"))
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

    # one file per week offset: the TRMNL device has no way to tell a plugin
    # which week to show, so each week is its own polling URL and its own
    # plugin instance. Stepping through the playlist is what moves weeks.
    weeks = []
    for offset in WEEK_OFFSETS:
        grid = week(calendars, offset)
        grid["generated_at"] = payload["generated_at"]
        grid["sources"] = payload["sources"]
        # no "+" in the filename: it is legal in a path segment but enough
        # clients and proxies decode it as a space that it is not worth the risk.
        if offset == 0:
            name = "week.json"
        elif offset == -1:
            name = "week-prev.json"
        elif offset == 1:
            name = "week-next.json"
        else:
            name = f"week-{'m' if offset < 0 else 'p'}{abs(offset)}.json"
        write_atomic(os.path.join(out_dir, name), json.dumps(grid, indent=2))
        weeks.append(f"{name}:{grid['total_events']}")

    log(f"wrote {len(payload['events'])} events from {len(calendars)} sources; weeks {' '.join(weeks)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
