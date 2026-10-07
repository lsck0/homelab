"""Build the TRMNL GitHub payload: failing, waiting, recently moved.

Usage: github-sync.py <out-dir>
Env:   GITHUB_TOKEN_FILE (a read-only token), GITHUB_USER, GITHUB_PRIVATE (1: include private repos), the row knobs

The payload goes to TRMNL's cloud, so only public repos, their ci notifications and their issues and pull
requests are in it unless GITHUB_PRIVATE=1: the token sees the private ones, the panel must not show them.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import feed_io

API = "https://api.github.com"
USER = os.environ.get("GITHUB_USER", "lsck0")
TOKEN_FILE = os.environ.get("GITHUB_TOKEN_FILE")
INCLUDE_PRIVATE = os.environ.get("GITHUB_PRIVATE", "0") == "1"
TIMEOUT_S = 30
PERCENT = 100
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
SECONDS_PER_DAY = 86400
# the two commit counts in the header
COMMITS_SHORT_DAYS = 7
COMMITS_LONG_DAYS = 30
# the notification reason of a workflow run; every other reason is an alert
REASON_CI = "ci_activity"
# the api's largest page; one page covers the owner's repos and notifications
PAGE_SIZE_MAX = 100

# rows per list before cutting
CI_ROWS = int(os.environ.get("GITHUB_CI_ROWS", "9"))
# two columns of 16 fill the wide box
REPO_ROWS = int(os.environ.get("GITHUB_REPO_ROWS", "32"))
WORK_ROWS = int(os.environ.get("GITHUB_WORK_ROWS", "6"))
LANG_ROWS = int(os.environ.get("GITHUB_LANG_ROWS", "8"))
# characters that fit a column of the panel
REPO_NAME_CHARS = 20
LANG_CHARS = 8
WORK_REPO_CHARS = 14
WORK_TITLE_CHARS = 34
CI_WHAT_CHARS = 22


def get(path, token, accept="application/vnd.github+json"):
    req = urllib.request.Request(f"{API}/{path}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", accept)
    req.add_header("User-Agent", f"homelab-github-sync/1.0 (+{USER})")
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
        return json.loads(r.read() or "null")


def safe(path, token, default, **kw):
    """A section that cannot be fetched leaves a hole, not an empty panel."""
    try:
        return get(path, token, **kw)
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        print(f"github: {path.split('?')[0]} failed: {e}", file=sys.stderr)
        return default


def ago(iso, now):
    """Compact age: 4m, 3h, 2d. The panel is read across a room."""
    if not iso:
        return ""
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return ""
    s = (now - t).total_seconds()
    if s < SECONDS_PER_HOUR:
        return f"{int(s // SECONDS_PER_MINUTE)}m"
    if s < SECONDS_PER_DAY:
        return f"{int(s // SECONDS_PER_HOUR)}h"
    return f"{int(s // SECONDS_PER_DAY)}d"


def commits(token, days):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    q = urllib.parse.quote(f"author:{USER} author-date:>={since}", safe=":>=")
    # commit search needs its own Accept header, else 415
    r = safe(f"search/commits?q={q}&per_page=1", token, {},
             accept="application/vnd.github.cloak-preview+json")
    return r.get("total_count", 0)


def public(repository, include_private):
    """Whether a repo (a repos or a notification entry) may go to the panel."""
    return include_private or not (repository or {}).get("private", True)


def payload_build(repos, notes, issues, prs, commits7, commits30, now, include_private=INCLUDE_PRIVATE):
    """The panel's payload from the API answers; private repos and what is in them left out unless included."""
    repos = [r for r in repos if public(r, include_private)]
    notes = [n for n in notes if public(n.get("repository"), include_private)]

    # only ci failures are actionable; the rest are counted
    ci = [n for n in notes if n.get("reason") == REASON_CI]
    alerts = [n for n in notes if n.get("reason") != REASON_CI]

    # one row per repo, not per run
    by_repo = {}
    for n in ci:
        name = (n.get("repository") or {}).get("name", "?")
        row = by_repo.setdefault(name, {"name": name, "n": 0, "last": "", "what": ""})
        row["n"] += 1
        updated = n.get("updated_at", "")
        if updated > row["last"]:
            row["last"] = updated
            row["what"] = n.get("subject", {}).get("title", "").split(" workflow run")[0][:CI_WHAT_CHARS]
    ci_rows = sorted(by_repo.values(), key=lambda row: (-row["n"], row["name"]))[:CI_ROWS]
    for row in ci_rows:
        row["age"] = ago(row["last"], now)

    active = [{
        "name": r["name"][:REPO_NAME_CHARS],
        "lang": (r.get("language") or "-")[:LANG_CHARS],
        "stars": r.get("stargazers_count", 0),
        "age": ago(r.get("pushed_at"), now),
    } for r in repos[:REPO_ROWS]]

    work = []
    for kind, res in (("issue", issues), ("pr", prs)):
        for i in (res.get("items") or [])[:WORK_ROWS]:
            work.append({
                "kind": kind,
                "repo": i.get("repository_url", "").rsplit("/", 1)[-1][:WORK_REPO_CHARS],
                "title": (i.get("title") or "")[:WORK_TITLE_CHARS],
                "age": ago(i.get("created_at"), now),
            })
    work = work[:WORK_ROWS]

    # from the repo list, not per-repo /languages calls
    langs = {}
    for r in repos:
        lang = r.get("language")
        if lang:
            langs[lang] = langs.get(lang, 0) + 1
    ranked = sorted(langs.items(), key=lambda kv: (-kv[1], kv[0]))[:LANG_ROWS]
    top = ranked[0][1] if ranked else 1
    # liquid can't slice; split columns here
    half = (len(active) + 1) // 2
    return {
        "generated": now.strftime("%H:%M"),
        "user": USER,
        "commits7": commits7,
        "commits30": commits30,
        "repos": len(repos),
        "stars": sum(r.get("stargazers_count", 0) for r in repos),
        "issues": issues.get("total_count", 0),
        "prs": prs.get("total_count", 0),
        "ci_failing": len(by_repo),
        "ci_runs": len(ci),
        "alerts": len(alerts),
        "ci": ci_rows,
        "active_a": active[:half],
        "active_b": active[half:],
        "work": work,
        # share of the leader, not the total; empty is normal, the panel says so
        "langs": [{"name": k, "n": v, "pct": round(PERCENT * v / top)} for k, v in ranked],
        "work_empty": not work,
    }


def main():
    if len(sys.argv) != 2 or not TOKEN_FILE:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    out = sys.argv[1]
    with open(TOKEN_FILE) as fh:
        token = fh.read().strip()
    if not token:
        print("the GitHub token is empty", file=sys.stderr)
        return 1

    repos = safe(f"user/repos?per_page={PAGE_SIZE_MAX}&affiliation=owner&sort=pushed", token, [])
    notes = safe(f"notifications?per_page={PAGE_SIZE_MAX}", token, [])

    def search(kind):
        # the search sees private issues too; is:public keeps them out unless included
        visibility = "" if INCLUDE_PRIVATE else " is:public"
        q = urllib.parse.quote(f"is:open is:{kind} involves:{USER}{visibility}")
        return safe(f"search/issues?q={q}&per_page={WORK_ROWS}", token, {})

    payload = payload_build(repos, notes, search("issue"), search("pr"),
                            commits(token, COMMITS_SHORT_DAYS), commits(token, COMMITS_LONG_DAYS),
                            datetime.now(timezone.utc))
    os.makedirs(out, exist_ok=True)
    feed_io.file_write_atomic(os.path.join(out, "github.json"), json.dumps(payload))
    print(f"github: {payload['commits7']} commits/7d, {payload['repos']} repos, "
          f"{payload['ci_failing']} repos with failing CI, {payload['issues']} issues, "
          f"{payload['prs']} PRs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
