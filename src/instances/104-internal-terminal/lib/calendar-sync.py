"""Merge ICS feeds into one calendar and the TRMNL calendar views.

Usage: calendar-sync.py <views-dir> <ics-dir>
Env:   CALENDAR_SOURCES (file of NAME|URL lines), CALENDAR_UPLOAD_DIR (pushed .ics files), CALENDAR_TZ, and the
       layout knobs below

Writes the week, day and month views (json, for TRMNL: titles, times and locations only) into <views-dir>, and
every source merged into merged.ics into <ics-dir>, which 104-internal-terminal/main.nix publishes on a token TRMNL
never sees: the ics holds descriptions, attendees and meeting links.
"""

import copy
import json
import os
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import feed_io
import recurring_ical_events
from icalendar import Calendar

FETCH_TIMEOUT_S = 30
USER_AGENT = "homelab-calendar-sync/1"
SECONDS_PER_MINUTE = 60
MINUTES_PER_HOUR = 60
MINUTES_PER_DAY = 1440
DAYS_PER_WEEK = 7
MONTHS_PER_YEAR = 12
# date.weekday() of the first weekend day
SATURDAY = 5
PERCENT = 100.0
# a day's time axis never shows less than four hours
GRID_SPAN_MIN_MINUTES = 240
# an event without an end, or ending where it starts, gets half an hour
EVENT_DEFAULT_MINUTES = 30
# the thinnest block still drawn, percent of the grid
BLOCK_MIN_PCT = 2.2
# how much text a block holds: under 90 min one line, from 150 min the location too
COMPACT_UNDER_MINUTES = 90
TALL_FROM_MINUTES = 150
# day columns start at local midnight
LOCAL_TZ = ZoneInfo(os.environ.get("CALENDAR_TZ", "Europe/Berlin"))
# weeks to publish, offsets from the current one
WEEK_OFFSETS = [int(o) for o in os.environ.get("CALENDAR_WEEK_OFFSETS", "-1,0,1").split(",")]
# month cell events before collapsing into "+n"
MONTH_CELL_EVENTS = int(os.environ.get("CALENDAR_MONTH_CELL_EVENTS", "3"))
# all-day events push the time grid down
ALLDAY_CELL_EVENTS = int(os.environ.get("CALENDAR_ALLDAY_CELL_EVENTS", "2"))
# time axis window, every hour drawn
GRID_START_MIN = int(os.environ.get("CALENDAR_GRID_START_MIN", "480"))
GRID_END_MIN = int(os.environ.get("CALENDAR_GRID_END_MIN", "1260"))
# smallest block, percent of grid height
WEEK_MIN_BLOCK_PCT = float(os.environ.get("CALENDAR_WEEK_MIN_BLOCK_PCT", "4.7"))
DAY_MIN_BLOCK_PCT = float(os.environ.get("CALENDAR_DAY_MIN_BLOCK_PCT", "9.5"))

# source display names
SOURCE_LABELS = dict(
    pair.split("=", 1)
    for pair in os.environ.get(
        "CALENDAR_SOURCE_LABELS", "proton=Private,uni=University,work=Work"
    ).split(",")
    if "=" in pair
)

# monochrome e-ink: borders instead of colours
BORDER_STYLES = ["solid", "dashed", "dotted", "double"]
_border_assigned = {}


def border_style(name):
    if name not in _border_assigned:
        _border_assigned[name] = BORDER_STYLES[len(_border_assigned) % len(BORDER_STYLES)]
    return _border_assigned[name]


def read_sources(path):
    """Parse NAME|URL lines, ignoring blanks and comments."""
    sources = []
    if not os.path.exists(path):
        feed_io.log(f"sources file {path} missing")
        return sources
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "|" not in line:
                feed_io.log(f"ignoring malformed source line: {line!r}")
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
    with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_S) as response:
        return response.read()


def uploaded_sources(upload_dir):
    """Uploaded .ics files as (name, file URL); filename is the source."""
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
        except Exception as err:  # noqa: BLE001 (one bad feed must not stop the rest)
            feed_io.log(f"source {name}: {err}")
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
                # copy: the views expand the unprefixed sources afterwards
                component = copy.deepcopy(component)
                # prefix UIDs: sources may reuse them
                uid = str(component.get("uid", ""))
                component["UID"] = f"{name}-{uid}"
                component["CATEGORIES"] = name
                merged.add_component(component)
    return merged


def to_iso(value):
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def minutes_into(day, value):
    """Local minutes from midnight of `day`, clamped to that day."""
    if not isinstance(value, datetime):
        return None
    delta = value.astimezone(LOCAL_TZ) - datetime.combine(day, datetime.min.time(), LOCAL_TZ)
    return max(0, min(MINUTES_PER_DAY, int(delta.total_seconds() // SECONDS_PER_MINUTE)))


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
        # some work invites lack a SUMMARY
        "summary": str(event.get("SUMMARY", "")).strip() or "(no title)",
        "location": str(event.get("LOCATION", "")),
        "start": to_iso(start_value) if start_value is not None else None,
        "end": to_iso(stop_value) if stop_value is not None else None,
        "all_day": all_day,
        # pre-rendered so liquid needn't parse timestamps
        "time": "" if all_day or start_value is None
                else start_value.astimezone(LOCAL_TZ).strftime("%H:%M"),
    }

    # minute offsets for a real time grid
    if day is not None and not all_day:
        begin = minutes_into(day, start_value)
        finish = minutes_into(day, stop_value) if stop_value is not None else None
        if begin is not None:
            if finish is None or finish <= begin:
                finish = min(MINUTES_PER_DAY, begin + EVENT_DEFAULT_MINUTES)
            row["start_min"] = begin
            row["end_min"] = finish
            midnight = datetime.combine(day, datetime.min.time(), LOCAL_TZ)
            row["end_time"] = (midnight + timedelta(minutes=finish)).strftime("%H:%M")
    return row


def assign_lanes(events):
    """Greedy lane packing; lanes is the densest cluster width."""
    timed = [e for e in events if "start_min" in e]
    timed.sort(key=lambda e: (e["start_min"], -(e["end_min"] - e["start_min"])))

    lane_ends = []          # end minute of each lane's last event
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
    """Enforce a minimum block height per lane, pushing later ones down."""
    lanes = {}
    for e in events:
        lanes.setdefault(e.get("lane", 0), []).append(e)
    for lane in lanes.values():
        lane.sort(key=lambda e: e["top_pct"])
        bottom = 0.0
        for e in lane:
            top = max(e["top_pct"], bottom)
            height = max(e["height_pct"], min_pct)
            if top + height > PERCENT:
                top = max(0.0, PERCENT - height)
            e["top_pct"] = round(top, 3)
            e["height_pct"] = round(min(height, PERCENT - top), 3)
            bottom = e["top_pct"] + e["height_pct"]


def week(calendars, offset, today):
    """One Monday-to-Sunday grid, `offset` weeks from the one holding `today`."""
    monday = today - timedelta(days=today.weekday()) + timedelta(weeks=offset)
    sunday = monday + timedelta(days=DAYS_PER_WEEK - 1)

    start = datetime.combine(monday, datetime.min.time(), LOCAL_TZ)
    end = start + timedelta(days=DAYS_PER_WEEK)

    by_day = {monday + timedelta(days=i): [] for i in range(DAYS_PER_WEEK)}
    for name, calendar in calendars:
        try:
            occurrences = recurring_ical_events.of(calendar).between(start, end)
        except Exception as err:  # noqa: BLE001 (keep the other sources)
            feed_io.log(f"expanding {name} for week {offset:+d}: {err}")
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
        all_day = [e for e in rows if e["all_day"]]
        days.append({
            "date": day.isoformat(),
            "day": day.day,
            "weekday": day.strftime("%a"),
            "is_today": day == today,
            "events": rows,
            "all_day_events": all_day[:ALLDAY_CELL_EVENTS],
            "all_day_more": max(0, len(all_day) - ALLDAY_CELL_EVENTS),
            "timed_events": timed,
            "max_lanes": max([e.get("lanes", 1) for e in timed], default=1),
        })

    grid_start, grid_end = max(0, GRID_START_MIN), min(MINUTES_PER_DAY, GRID_END_MIN)
    if grid_end - grid_start < GRID_SPAN_MIN_MINUTES:
        grid_end = min(MINUTES_PER_DAY, grid_start + GRID_SPAN_MIN_MINUTES)

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
            top = (e["start_min"] - grid_start) / span * PERCENT
            height = (e["end_min"] - e["start_min"]) / span * PERCENT
            lanes = e.get("lanes", 1) or 1
            e["top_pct"] = round(max(0.0, min(PERCENT, top)), 3)
            e["height_pct"] = round(max(BLOCK_MIN_PCT, min(PERCENT - e["top_pct"], height)), 3)
            e["left_pct"] = round(e.get("lane", 0) / lanes * PERCENT, 3)
            e["width_pct"] = round(PERCENT / lanes, 3)
            e["overlapping"] = lanes > 1
            dur = e["end_min"] - e["start_min"]
            e["compact"] = dur < COMPACT_UNDER_MINUTES
            e["tall"] = dur >= TALL_FROM_MINUTES
        enforce_min_height(d["timed_events"], WEEK_MIN_BLOCK_PCT)

    hours = []
    for m in range(grid_start, grid_end + 1, MINUTES_PER_HOUR):
        hours.append({
            "label": f"{m // MINUTES_PER_HOUR:02d}:00",
            "hour": m // MINUTES_PER_HOUR,
            # label every other hour to keep the axis readable
            "major": (m // MINUTES_PER_HOUR) % 2 == 0,
            "top_pct": round((m - grid_start) / span * PERCENT, 3),
        })

    same_month = monday.strftime("%b") == sunday.strftime("%b")
    label = (f"{monday.day} to {sunday.day} {sunday.strftime('%b %Y')}" if same_month
             else f"{monday.day} {monday.strftime('%b')} to {sunday.day} {sunday.strftime('%b %Y')}")

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
            "start_label": f"{grid_start // MINUTES_PER_HOUR:02d}:00",
            "end_label": f"{grid_end // MINUTES_PER_HOUR:02d}:00",
            "hours": hours,
        },
        "days": days,
    }


def day_view(calendars, offset, today):
    """One day as a time grid. Same lane packing as the week, more room per event."""
    grid = week(calendars, 0, today)
    want = (today + timedelta(days=offset)).isoformat()

    match = next((d for d in grid["days"] if d["date"] == want), None)
    if match is None:                      # offset fell outside the current week
        grid = week(calendars, 1 if offset > 0 else -1, today)
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
        # same `days` shape so one markup serves both
        "days": [match],
    }


def month_view(calendars, offset, today):
    """Monday-first month grid built from the week builder."""
    first = date(today.year + (today.month + offset - 1) // MONTHS_PER_YEAR,
                 (today.month + offset - 1) % MONTHS_PER_YEAR + 1, 1)
    grid_start = first - timedelta(days=first.weekday())
    last = date(first.year + first.month // MONTHS_PER_YEAR, first.month % MONTHS_PER_YEAR + 1, 1) - timedelta(days=1)
    grid_end = last + timedelta(days=DAYS_PER_WEEK - 1 - last.weekday())

    # every displayed day, from the weeks it spans
    by_date = {}
    probe = grid_start
    while probe <= grid_end:
        offset_weeks = (probe - (today - timedelta(days=today.weekday()))).days // DAYS_PER_WEEK
        for d in week(calendars, offset_weeks, today)["days"]:
            by_date[d["date"]] = d
        probe += timedelta(days=DAYS_PER_WEEK)

    weeks = []
    cursor = grid_start
    while cursor <= grid_end:
        row = {"week_number": cursor.isocalendar().week, "days": []}
        for _ in range(DAYS_PER_WEEK):
            src = by_date.get(cursor.isoformat())
            events = src["events"] if src else []
            row["days"].append({
                "date": cursor.isoformat(),
                "day": cursor.day,
                "weekday": cursor.strftime("%a"),
                "is_today": cursor == today,
                "other_month": cursor.month != first.month,
                "is_weekend": cursor.weekday() >= SATURDAY,
                "count": len(events),
                # only the first few fit; the rest become "+n"
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


def main():
    if len(sys.argv) != 3 or "CALENDAR_SOURCES" not in os.environ:
        feed_io.log(__doc__.split("\n\n")[1])
        return 2
    sources_file = os.environ["CALENDAR_SOURCES"]
    out_dir, ics_dir = sys.argv[1], sys.argv[2]
    today = datetime.now(LOCAL_TZ).date()

    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(ics_dir, exist_ok=True)

    sources = read_sources(sources_file) + uploaded_sources(os.environ.get("CALENDAR_UPLOAD_DIR"))
    if not sources:
        feed_io.log("no calendar sources configured")

    calendars = load_calendars(sources)
    if sources and not calendars:
        feed_io.log("every source failed, keeping previous output")
        return 1

    feed_io.file_write_atomic(os.path.join(ics_dir, "merged.ics"), merge(calendars).to_ical())

    generated_at = datetime.now(timezone.utc).isoformat()
    source_names = [name for name, _ in sources]

    # one file per week: the device can't pick a week
    weeks = []
    for offset in WEEK_OFFSETS:
        grid = week(calendars, offset, today)
        grid["generated_at"] = generated_at
        grid["sources"] = source_names
        # no "+" in filenames: some clients and proxies mangle it
        if offset == 0:
            name = "week.json"
        elif offset == -1:
            name = "week-prev.json"
        elif offset == 1:
            name = "week-next.json"
        else:
            name = f"week-{'m' if offset < 0 else 'p'}{abs(offset)}.json"
        feed_io.file_write_atomic(os.path.join(out_dir, name), json.dumps(grid, indent=2))
        weeks.append(f"{name}:{grid['total_events']}")

    for name, payload in [("day.json", day_view(calendars, 0, today)),
                          ("day-next.json", day_view(calendars, 1, today)),
                          ("month.json", month_view(calendars, 0, today)),
                          ("month-next.json", month_view(calendars, 1, today))]:
        payload["generated_at"] = generated_at
        payload["sources"] = source_names
        feed_io.file_write_atomic(os.path.join(out_dir, name), json.dumps(payload, indent=2))
        weeks.append(f"{name}:{payload['total_events']}")

    feed_io.log(f"wrote {len(calendars)} sources; views {' '.join(weeks)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
