"""Build the TRMNL arXiv payload from the math RSS feed (the API lags days).

Usage: arxiv-sync.py <out-dir>
Env:   ARXIV_FEED, ARXIV_ROWS, ARXIV_AUTHORS, ARXIV_TYPES
"""
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from itertools import zip_longest

import feed_io

FEED = os.environ.get("ARXIV_FEED", "https://rss.arxiv.org/rss/math")
# 12 rows of 32px fill 380px; 14 clipped
ROWS = int(os.environ.get("ARXIV_ROWS", "12"))
# surnames shown before the list collapses to "+n"
AUTHORS = int(os.environ.get("ARXIV_AUTHORS", "8"))
# "new" only; skip cross-lists and replacements
TYPES = set(os.environ.get("ARXIV_TYPES", "new").split(","))
FETCH_TIMEOUT_S = 30
# subjects counted in the header
SUBJECT_ROWS = 5
# arxiv asks callers to identify themselves
USER_AGENT = "homelab-trmnl/1.0 (+https://lsck0.dev)"
DC = "{http://purl.org/dc/elements/1.1/}"
ARXIV = "{http://arxiv.org/schemas/atom}"

# names for common primary categories
SUBJECTS = {
    "math.AC": "Commutative Algebra", "math.AG": "Algebraic Geometry",
    "math.AP": "Analysis of PDEs", "math.AT": "Algebraic Topology",
    "math.CA": "Classical Analysis", "math.CO": "Combinatorics",
    "math.CT": "Category Theory", "math.CV": "Complex Variables",
    "math.DG": "Differential Geometry", "math.DS": "Dynamical Systems",
    "math.FA": "Functional Analysis", "math.GM": "General Mathematics",
    "math.GN": "General Topology", "math.GR": "Group Theory",
    "math.GT": "Geometric Topology", "math.HO": "History and Overview",
    "math.IT": "Information Theory", "math.KT": "K-Theory",
    "math.LO": "Logic", "math.MG": "Metric Geometry",
    "math.MP": "Mathematical Physics", "math.NA": "Numerical Analysis",
    "math.NT": "Number Theory", "math.OA": "Operator Algebras",
    "math.OC": "Optimization and Control", "math.PR": "Probability",
    "math.QA": "Quantum Algebra", "math.RA": "Rings and Algebras",
    "math.RT": "Representation Theory", "math.SG": "Symplectic Geometry",
    "math.SP": "Spectral Theory", "math.ST": "Statistics Theory",
    # cross-lists in the math feed use non-math codes
    "math-ph": "Mathematical Physics", "cs.IT": "Information Theory",
    "cs.LG": "Machine Learning", "cs.DM": "Discrete Mathematics",
    "cs.NA": "Numerical Analysis", "cs.DS": "Data Structures",
    "cs.CC": "Computational Complexity", "cs.LO": "Logic in CS",
    "stat.ML": "Machine Learning", "stat.TH": "Statistics Theory",
    "stat.ME": "Statistics Methodology", "stat.AP": "Applied Statistics",
    "q-fin.MF": "Mathematical Finance", "nlin.SI": "Integrable Systems",
    "nlin.CD": "Chaotic Dynamics", "cond-mat.stat-mech": "Statistical Mechanics",
    "quant-ph": "Quantum Physics", "gr-qc": "General Relativity",
    "hep-th": "High Energy Theory", "eess.SP": "Signal Processing",
    "eess.SY": "Systems and Control",
}

# titles are tex
TEX_COMMANDS = re.compile(r"\\(?:mathcal|mathbb|mathbf|mathrm|mathfrak|mathscr|text|rm|bf|it)\s*")
TEX_BRACES = re.compile(r"[{}$]")

# strip bracketed affiliations and tex accents
AFFILIATION = re.compile(r"\s*\([^)]*\)")
TEX_ACCENTS = re.compile(r"\\[a-zA-Z]+\s*|\\[`'^\"~=.]")


def detex(s):
    s = TEX_COMMANDS.sub("", s)
    s = TEX_BRACES.sub("", s)
    return " ".join(s.split())


def detex_name(s):
    s = TEX_ACCENTS.sub("", s)
    s = TEX_BRACES.sub("", s)
    return " ".join(s.split())


def fetch():
    req = urllib.request.Request(FEED, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT_S) as r:
        return ET.fromstring(r.read())


def authors(entry, limit=AUTHORS):
    raw = entry.findtext(DC + "creator") or ""
    # before the split: affiliations may contain commas
    raw = AFFILIATION.sub("", raw)
    names = [detex_name(n) for n in raw.split(",")]
    names = [n for n in names if n]
    if not names:
        return ""
    # surname only: full names overflow 800px
    short = [n.rsplit(" ", 1)[-1] for n in names]
    if len(short) <= limit:
        return ", ".join(short)
    return ", ".join(short[:limit]) + f" +{len(short) - limit}"


def parse_date(raw):
    """RFC 822 date; email.utils handles named offsets and optional weekday."""
    try:
        return parsedate_to_datetime(raw).astimezone()
    except (TypeError, ValueError):
        return None


def payload_build(channel, now):
    """The panel's payload from the feed's channel element: the newest announcement day, grouped by subject."""
    entries = []
    for item in channel.findall("item"):
        kind = item.findtext(ARXIV + "announce_type") or ""
        if TYPES and kind not in TYPES:
            continue
        when = parse_date(item.findtext("pubDate") or "")
        if when is None:
            continue
        link = item.findtext("link") or ""
        code = item.findtext("category") or ""
        entries.append({
            "id": link.rsplit("/", 1)[-1],
            "title": detex(item.findtext("title") or ""),
            "authors": authors(item),
            "subject": SUBJECTS.get(code, code),
            "code": code,
            "published": when.isoformat(),
            "day": when.date(),
        })

    # one batch per feed; newest date labels it
    label_day = max((e["day"] for e in entries), default=now.date())
    todays = [e for e in entries if e["day"] == label_day]

    by_subject = {}
    for e in todays:
        by_subject[e["subject"]] = by_subject.get(e["subject"], 0) + 1
    ranked = sorted(by_subject.items(), key=lambda kv: (-kv[1], kv[0]))

    for e in todays:
        del e["day"]

    # group by subject; submission order interleaved them
    groups = [sorted((e for e in todays if e["subject"] == s), key=lambda e: e["id"])
              for s, _ in ranked]
    shown = [e for tier in zip_longest(*groups) for e in tier if e is not None]

    return {
        "view": "arxiv",
        "generated_at": now.isoformat(),
        "label": label_day.strftime("%a %d %b"),
        "is_today": label_day == now.date(),
        "total": len(todays),
        "papers": shown[:ROWS],
        "more": max(0, len(todays) - ROWS),
        "subjects": [{"name": n, "count": c} for n, c in ranked[:SUBJECT_ROWS]],
    }


def main():
    if len(sys.argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out_dir = sys.argv[1]

    try:
        feed = fetch()
    except (urllib.error.URLError, socket.timeout, ET.ParseError) as e:
        print(f"arxiv feed failed: {e}", file=sys.stderr)
        return 1

    channel = feed.find("channel")
    if channel is None:
        print("arxiv feed has no channel", file=sys.stderr)
        return 1

    payload = payload_build(channel, datetime.now(timezone.utc).astimezone())
    os.makedirs(out_dir, exist_ok=True)
    feed_io.file_write_atomic(os.path.join(out_dir, "arxiv.json"), json.dumps(payload, indent=2))
    print(f"{payload['total']} math papers for {payload['label']}, showing {len(payload['papers'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
