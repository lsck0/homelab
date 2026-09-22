"""Build the TRMNL arXiv payload: today's mathematics submissions.

Runs on vm-104 beside the other terminal feeds and writes
<out-dir>/arxiv.json, which nginx serves under the same token.

Source is the daily announcement feed, https://rss.arxiv.org/rss/math, not the
search API. The API's index lags several days - queried on 22 Sep it had
nothing newer than the 18th - while the RSS feed is the announcement itself and
carries announce_type, so genuinely new papers can be told from cross-lists and
replacements. http:// answers 301; both only work over https.

One request an hour, well inside arXiv's one-every-three-seconds request.
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

FEED = os.environ.get("ARXIV_FEED", "https://rss.arxiv.org/rss/math")
ROWS = int(os.environ.get("ARXIV_ROWS", "14"))
# surnames shown before the list collapses to "+n"
AUTHORS = int(os.environ.get("ARXIV_AUTHORS", "8"))
# cross-lists and replacements are announced in the same feed; "new" alone is
# what "today's publications" means.
TYPES = set(os.environ.get("ARXIV_TYPES", "new").split(","))
TIMEOUT = 30
DC = "{http://purl.org/dc/elements/1.1/}"
ARXIV = "{http://arxiv.org/schemas/atom}"

# the primary category is what the paper is filed under; spell the common ones
# out, because "math.AG" means nothing at a glance across the room.
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
    # cross-lists are announced in the maths feed too and are not math.* codes
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

# Titles are TeX. A panel read from across the room cannot render it, and the
# markup is noisier than what it encodes, so unwrap the inline maths and drop
# the commands that only pick a font. Anything left is shown verbatim: a real
# TeX renderer is not worth carrying for a nine-line list.
TEX_COMMANDS = re.compile(r"\\(?:mathcal|mathbb|mathbf|mathrm|mathfrak|mathscr|text|rm|bf|it)\s*")
TEX_BRACES = re.compile(r"[{}$]")


def detex(s):
    s = TEX_COMMANDS.sub("", s)
    s = TEX_BRACES.sub("", s)
    return " ".join(s.split())


def fetch():
    req = urllib.request.Request(FEED, headers={
        # arXiv asks callers to identify themselves
        "User-Agent": "homelab-trmnl/1.0 (+https://lsck0.dev)",
    })
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return ET.fromstring(r.read())


def authors(entry, limit=AUTHORS):
    raw = entry.findtext(DC + "creator") or ""
    names = [n.strip() for n in raw.split(",") if n.strip()]
    if not names:
        return ""
    # surname only: full names eat the row on an 800px panel
    short = [n.rsplit(" ", 1)[-1] for n in names]
    if len(short) <= limit:
        return ", ".join(short)
    return ", ".join(short[:limit]) + f" +{len(short) - limit}"


def parse_date(raw):
    """RFC 822, as RSS uses. email.utils rather than strptime: the offset can be
    numeric or a name, and the day-of-week is optional."""
    try:
        return parsedate_to_datetime(raw).astimezone()
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) < 2:
        print("usage: arxiv-sync.py <out-dir>", file=sys.stderr)
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

    now = datetime.now(timezone.utc).astimezone()
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

    # The feed is one announcement batch, so every item shares a date; taking
    # the newest present keeps this honest on the days arXiv does not announce
    # (weekends and US holidays) instead of reporting an empty today.
    label_day = max((e["day"] for e in entries), default=now.date())
    todays = [e for e in entries if e["day"] == label_day]

    by_subject = {}
    for e in todays:
        by_subject[e["subject"]] = by_subject.get(e["subject"], 0) + 1
    top = sorted(by_subject.items(), key=lambda kv: (-kv[1], kv[0]))[:5]

    for e in todays:
        del e["day"]

    payload = {
        "view": "arxiv",
        "generated_at": now.isoformat(),
        "label": label_day.strftime("%a %d %b"),
        "is_today": label_day == now.date(),
        "total": len(todays),
        "papers": todays[:ROWS],
        "more": max(0, len(todays) - ROWS),
        "subjects": [{"name": n, "count": c} for n, c in top],
    }

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "arxiv.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(payload, indent=2))
    os.replace(tmp, path)
    print(f"{len(todays)} math papers for {label_day}, showing {len(payload['papers'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
