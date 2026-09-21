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
# how many events a month cell shows before collapsing the rest into "+n".
# Six rows share 434px, so a cell holds its date plus two lines and the
# "+n more"; a third line was drawn half outside the cell and clipped.
MONTH_CELL_EVENTS = int(os.environ.get("CALENDAR_MONTH_CELL_EVENTS", "2"))
# All-day events sit above the time grid and push it down, so a day with eight
# of them would leave no room for the hours. Show a few, count the rest.
ALLDAY_CELL_EVENTS = int(os.environ.get("CALENDAR_ALLDAY_CELL_EVENTS", "2"))
# The time axis spans this window, every hour drawn, so a given hour is always
# at the same height and the screen reads at a glance. 07:00-22:00, not the
# full day: on a 480px panel 24 rows left ~13px per hour, so the hour labels
# overlapped each other and every event was shorter than its own text. The
# night is empty on every calendar here, and an event outside the window still
# widens it (below) rather than being hidden. 08:00-24:00 by request.
GRID_START_MIN = int(os.environ.get("CALENDAR_GRID_START_MIN", "480"))
GRID_END_MIN = int(os.environ.get("CALENDAR_GRID_END_MIN", "960"))
# Smallest block, as a percentage of the grid height. Percent positions are
# exact but text is not: a 30-minute block is ~15px tall and one line of text
# needs about that, so two back-to-back meetings drew on top of each other and
# the first one vanished. Blocks grow to this and push the ones below them
# down. The day view has one wide column and can afford more.
WEEK_MIN_BLOCK_PCT = float(os.environ.get("CALENDAR_WEEK_MIN_BLOCK_PCT", "4.7"))
DAY_MIN_BLOCK_PCT = float(os.environ.get("CALENDAR_DAY_MIN_BLOCK_PCT", "9.5"))

# Display names for the sources. The key is the source name (the part before
# "|" in calendar-sources, or an uploaded file's stem); the value is what the
# screen shows. A source with no mapping falls back to its own name.
SOURCE_LABELS = dict(
    pair.split("=", 1)
    for pair in os.environ.get(
        "CALENDAR_SOURCE_LABELS", "proton=Private,uni=University,work=Work"
    ).split(",")
    if "=" in pair
)

# Monochrome e-ink has no colour to spend on categories, so each source gets a
# border style instead. Assigned in the order sources are first seen, so adding
# or renaming one keeps working without touching the template.
BORDER_STYLES = ["solid", "dashed", "dotted", "double"]
_border_assigned = {}


def border_style(name):
    if name not in _border_assigned:
        _border_assigned[name] = BORDER_STYLES[len(_border_assigned) % len(BORDER_STYLES)]
    return _border_assigned[name]


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


def minutes_into(day, value):
    """Local minutes from midnight of `day`, clamped to that day."""
    if not isinstance(value, datetime):
        return None
    delta = value.astimezone(LOCAL_TZ) - datetime.combine(day, datetime.min.time(), LOCAL_TZ)
    return max(0, min(1440, int(delta.total_seconds() // 60)))


def event_row(name, event, day=None):
    """One event as the template consumes it."""
    start = event.get("DTSTART")
    stop = event.get("DTEND")
    start_value = start.dt if start is not None else None
    stop_value = stop.dt if stop is not None else None
    all_day = isinstance(start_value, date) and not isinstance(start_value, datetime)

    row = {
        "source": name,
        "source_label": SOURCE_LABELS.get(name, name.title()),
        "border_style": border_style(name),
        # some invites in the work feed carry no SUMMARY at all; without a
        # placeholder the block renders as an empty box on the screen.
        "summary": str(event.get("SUMMARY", "")).strip() or "(no title)",
        "location": str(event.get("LOCATION", "")),
        "start": to_iso(start_value) if start_value is not None else None,
        "end": to_iso(stop_value) if stop_value is not None else None,
        "all_day": all_day,
        # pre-rendered so the Liquid template does not have to parse a timestamp
        "time": "" if all_day or start_value is None
                else start_value.astimezone(LOCAL_TZ).strftime("%H:%M"),
    }

    # Minute offsets let the template lay the week out as a real time grid, so
    # two things at once sit side by side instead of stacking into a list that
    # hides the clash. Liquid cannot do date arithmetic, hence doing it here.
    if day is not None and not all_day:
        begin = minutes_into(day, start_value)
        finish = minutes_into(day, stop_value) if stop_value is not None else None
        if begin is not None:
            if finish is None or finish <= begin:
                finish = min(1440, begin + 30)   # zero-length or missing DTEND
            row["start_min"] = begin
            row["end_min"] = finish
            midnight = datetime.combine(day, datetime.min.time(), LOCAL_TZ)
            row["end_time"] = (midnight + timedelta(minutes=finish)).strftime("%H:%M")
    return row


def assign_lanes(events):
    """Give overlapping events side-by-side columns.

    Greedy sweep: an event reuses the first lane whose previous occupant has
    already ended, otherwise it opens a new one. `lanes` is then the width of
    the densest cluster the event belongs to, so a pair that clashes each takes
    half the day's width while an unclashed event still spans the whole column.
    """
    timed = [e for e in events if "start_min" in e]
    timed.sort(key=lambda e: (e["start_min"], -(e["end_min"] - e["start_min"])))

    lane_ends = []          # end minute of the last event placed in each lane
    cluster = []            # events in the current run of overlapping activity
    cluster_end = None

    def close(group, width):
        for member in group:
            member["lanes"] = width

    for ev in timed:
        if cluster_end is not None and ev["start_min"] >= cluster_end:
            close(cluster, len(lane_ends))
            cluster, lane_ends, cluster_end = [], [], None

        placed = False
        for i, end in enumerate(lane_ends):
            if end <= ev["start_min"]:
                lane_ends[i] = ev["end_min"]
                ev["lane"] = i
                placed = True
                break
        if not placed:
            ev["lane"] = len(lane_ends)
            lane_ends.append(ev["end_min"])

        cluster.append(ev)
        cluster_end = ev["end_min"] if cluster_end is None else max(cluster_end, ev["end_min"])

    close(cluster, len(lane_ends))
    return timed


def local_day(value):
    """The local calendar day an event belongs in."""
    if isinstance(value, datetime):
        return value.astimezone(LOCAL_TZ).date()
    return value


def enforce_min_height(events, min_pct):
    """Grow every block to a readable minimum and push the later ones down.

    Works per lane, so events that genuinely overlap in time keep their
    side-by-side placement and only a lane's own sequence is nudged.
    """
    lanes = {}
    for e in events:
        lanes.setdefault(e.get("lane", 0), []).append(e)
    for lane in lanes.values():
        lane.sort(key=lambda e: e["top_pct"])
        bottom = 0.0
        for e in lane:
            top = max(e["top_pct"], bottom)
            height = max(e["height_pct"], min_pct)
            if top + height > 100.0:
                top = max(0.0, 100.0 - height)
            e["top_pct"] = round(top, 3)
            e["height_pct"] = round(min(height, 100.0 - top), 3)
            bottom = e["top_pct"] + e["height_pct"]


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
                by_day[day].append(event_row(name, event, day))

    days = []
    for day in sorted(by_day):
        rows = sorted(by_day[day], key=lambda e: (not e["all_day"], e["time"]))
        timed = assign_lanes(rows)
        days.append({
            "date": day.isoformat(),
            "day": day.day,
            "weekday": day.strftime("%a"),
            "is_today": day == today,
            "events": rows,
            "all_day_events": [e for e in rows if e["all_day"]][:ALLDAY_CELL_EVENTS],
            "all_day_more": max(0, len([e for e in rows if e["all_day"]]) - ALLDAY_CELL_EVENTS),
            "timed_events": timed,
            # how many columns this day needs: the template does not have to
            # work it out, and an empty day still reports 1.
            "max_lanes": max([e.get("lanes", 1) for e in timed], default=1),
        })

    # The axis spans the whole configured day, every hour drawn, rather than
    # cropping to the hours that happen to be busy. A cropped axis silently
    # rescales: the same meeting sits at a different height each day, so the
    # screen cannot be read at a glance. A fixed day means 09:00 is always in
    # the same place, and an empty morning reads as an empty morning.
    #
    # GRID_START/GRID_END default to the full 24 hours; narrow them if the night
    # is wasted space on your panel.
    grid_start, grid_end = GRID_START_MIN, GRID_END_MIN

    # The window is exactly what was asked for. An earlier version widened it
    # to swallow any outlier, which meant one 21:00 meeting rescaled the whole
    # week and 08:00-16:00 silently became 08:00-21:00.
    #
    # Nothing is dropped silently instead: an event that starts after the
    # window is counted per day and in the footer, and one that merely runs
    # past the end is clipped to it.
    grid_start, grid_end = max(0, grid_start), min(1440, grid_end)
    if grid_end - grid_start < 240:
        grid_end = min(1440, grid_start + 240)

    for d in days:
        inside, later = [], 0
        for e in d["timed_events"]:
            if e["end_min"] <= grid_start or e["start_min"] >= grid_end:
                later += 1
            else:
                inside.append(e)
        d["timed_events"] = assign_lanes(inside) if later else inside
        d["later"] = later

    span = grid_end - grid_start
    for d in days:
        for e in d["timed_events"]:
            top = (e["start_min"] - grid_start) / span * 100
            height = (e["end_min"] - e["start_min"]) / span * 100
            lanes = e.get("lanes", 1) or 1
            e["top_pct"] = round(max(0.0, min(100.0, top)), 3)
            e["height_pct"] = round(max(2.2, min(100.0 - e["top_pct"], height)), 3)
            e["left_pct"] = round(e.get("lane", 0) / lanes * 100, 3)
            e["width_pct"] = round(100 / lanes, 3)
            e["overlapping"] = lanes > 1
            # How much text the block can hold. Three lines (time, title,
            # source) need ~35px; in the week a minute is ~0.47px, so anything
            # under 90 minutes printed three lines into a box too short for
            # them and the title was the line that got clipped away. Short
            # blocks get one line instead, "10:00 Standup", and keep their
            # source in the left border style. The day view has one wide
            # column and always shows all three.
            dur = e["end_min"] - e["start_min"]
            e["compact"] = dur < 90
            e["tall"] = dur >= 150
        enforce_min_height(d["timed_events"], WEEK_MIN_BLOCK_PCT)

    hours = []
    for m in range(grid_start, grid_end + 1, 60):
        hours.append({
            "label": f"{m // 60:02d}:00",
            "hour": m // 60,
            # the week packs 24 rows into one screen; labelling every other one
            # keeps the axis readable. The day view has room for all of them.
            "major": (m // 60) % 2 == 0,
            "top_pct": round((m - grid_start) / span * 100, 3),
        })

    same_month = monday.strftime("%b") == sunday.strftime("%b")
    label = (f"{monday.day}–{sunday.day} {sunday.strftime('%b %Y')}" if same_month
             else f"{monday.day} {monday.strftime('%b')} – {sunday.day} {sunday.strftime('%b %Y')}")

    return {
        "view": "week",
        "offset": offset,
        "label": label,
        "week_number": monday.isocalendar().week,
        "is_current": offset == 0,
        "start": monday.isoformat(),
        "end": sunday.isoformat(),
        "total_events": sum(len(d["events"]) for d in days),
        "has_all_day": any(d["all_day_events"] for d in days),
        "later": sum(d["later"] for d in days),
        "max_overlap": max([d["max_lanes"] for d in days], default=1),
        "grid": {
            "start_min": grid_start,
            "end_min": grid_end,
            "start_label": f"{grid_start // 60:02d}:00",
            "end_label": f"{grid_end // 60:02d}:00",
            "hours": hours,
        },
        "days": days,
    }


def day_view(calendars, offset=0):
    """One day as a time grid. Same lane packing as the week, more room per event."""
    grid = week(calendars, 0)
    today = datetime.now(LOCAL_TZ).date()
    want = (today + timedelta(days=offset)).isoformat()

    match = next((d for d in grid["days"] if d["date"] == want), None)
    if match is None:                      # offset fell outside the current week
        grid = week(calendars, 1 if offset > 0 else -1)
        match = next((d for d in grid["days"] if d["date"] == want), grid["days"][0])

    enforce_min_height(match["timed_events"], DAY_MIN_BLOCK_PCT)
    stamp = datetime.fromisoformat(match["date"])
    return {
        "view": "day",
        "offset": offset,
        "label": stamp.strftime("%A, %-d %B %Y"),
        "weekday": stamp.strftime("%A"),
        "is_today": match["is_today"],
        "total_events": len(match["events"]),
        "max_overlap": match["max_lanes"],
        "has_all_day": bool(match["all_day_events"]),
        "later": match.get("later", 0),
        "grid": grid["grid"],
        "day": match,
        # the week template iterates `days`; expose the single day the same way
        # so one markup renders both views without special-casing the shape.
        "days": [match],
    }


def month_view(calendars, offset=0):
    """A Monday-first month grid: every cell a day, every day its events.

    Built from the week builder so a cell's events are packed and ordered
    exactly as they are everywhere else; the month view just does not have the
    vertical room to draw them against a time axis.
    """
    today = datetime.now(LOCAL_TZ).date()
    first = date(today.year + (today.month + offset - 1) // 12,
                 (today.month + offset - 1) % 12 + 1, 1)
    grid_start = first - timedelta(days=first.weekday())
    last = date(first.year + first.month // 12, first.month % 12 + 1, 1) - timedelta(days=1)
    grid_end = last + timedelta(days=6 - last.weekday())

    # collect every day in the displayed range from the weeks it spans
    by_date = {}
    probe = grid_start
    while probe <= grid_end:
        offset_weeks = (probe - (today - timedelta(days=today.weekday()))).days // 7
        for d in week(calendars, offset_weeks)["days"]:
            by_date[d["date"]] = d
        probe += timedelta(days=7)

    weeks = []
    cursor = grid_start
    while cursor <= grid_end:
        row = {"week_number": cursor.isocalendar().week, "days": []}
        for _ in range(7):
            src = by_date.get(cursor.isoformat())
            events = src["events"] if src else []
            row["days"].append({
                "date": cursor.isoformat(),
                "day": cursor.day,
                "weekday": cursor.strftime("%a"),
                "is_today": cursor == today,
                "other_month": cursor.month != first.month,
                "is_weekend": cursor.weekday() >= 5,
                "count": len(events),
                # only the first few fit in a month cell; the rest become "+n".
                "events": events[:MONTH_CELL_EVENTS],
                "more": max(0, len(events) - MONTH_CELL_EVENTS),
            })
            cursor += timedelta(days=1)
        weeks.append(row)

    return {
        "view": "month",
        "offset": offset,
        "label": first.strftime("%B %Y"),
        "month": first.month,
        "year": first.year,
        "total_events": sum(d["count"] for w in weeks for d in w["days"] if not d["other_month"]),
        "weeks": weeks,
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

    # `payload` is rebound by the per-view loop below; keep a stable handle.
    out_payload = payload = {
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

    for name, payload in [("day.json", day_view(calendars, 0)),
                          ("day-next.json", day_view(calendars, 1)),
                          ("month.json", month_view(calendars, 0)),
                          ("month-next.json", month_view(calendars, 1))]:
        payload["generated_at"] = out_payload["generated_at"]
        payload["sources"] = out_payload["sources"]
        write_atomic(os.path.join(out_dir, name), json.dumps(payload, indent=2))
        weeks.append(f"{name}:{payload['total_events']}")

    log(f"wrote {len(out_payload['events'])} events from {len(calendars)} sources; views {' '.join(weeks)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
