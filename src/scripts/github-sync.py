"""Build the TRMNL GitHub payload: what is failing, what is waiting, what moved.

Runs on vm-104 beside the other terminal feeds and writes <out-dir>/github.json,
which nginx serves under the same token.

Shaped around what the account actually contains rather than what a GitHub
dashboard usually shows. Measured on 2026-09-24: 0 open issues, 0 open PRs, and
50 notifications of which 49 were failed CI runs - but those 49 collapse to 2
repos once grouped. So the repo list gets the wide column and everything else
is a counter or a short list.

One call per section, six in total, well inside the 5000/hour limit.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://api.github.com"
USER = os.environ.get("GITHUB_USER", "lsck0")
TOKEN_FILE = os.environ.get("GITHUB_TOKEN_FILE")
TIMEOUT = 30

# Rows each list can show before it is cut. The CI list gets the most because
# it is the only one with real volume; see the module docstring.
CI_ROWS = int(os.environ.get("GITHUB_CI_ROWS", "9"))
# two columns of 16 fill the wide box exactly; every repo gets a row.
REPO_ROWS = int(os.environ.get("GITHUB_REPO_ROWS", "32"))
WORK_ROWS = int(os.environ.get("GITHUB_WORK_ROWS", "6"))
LANG_ROWS = int(os.environ.get("GITHUB_LANG_ROWS", "8"))


def get(path, token, accept="application/vnd.github+json"):
    req = urllib.request.Request(f"{API}/{path}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", accept)
    req.add_header("User-Agent", f"homelab-github-sync/1.0 (+{USER})")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.loads(r.read() or "null")


def safe(path, token, default, **kw):
    """A section that cannot be fetched leaves a hole, not an empty panel."""
    try:
        return get(path, token, **kw)
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        print(f"github: {path.split('?')[0]} failed: {e}", file=sys.stderr)
        return default


def ago(iso):
    """Compact age: 4m, 3h, 2d. The panel is read across a room."""
    if not iso:
        return ""
    try:
        t = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return ""
    s = (datetime.now(timezone.utc) - t).total_seconds()
    if s < 3600:
        return f"{int(s // 60)}m"
    if s < 86400:
        return f"{int(s // 3600)}h"
    return f"{int(s // 86400)}d"


def commits(token, days):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    q = urllib.parse.quote(f"author:{USER} author-date:>={since}", safe=":>=")
    # the commit search needs its own Accept header; without it this 415s
    r = safe(f"search/commits?q={q}&per_page=1", token, {},
             accept="application/vnd.github.cloak-preview+json")
    return r.get("total_count", 0)


def main():
    if len(sys.argv) < 2:
        print("usage: github-sync.py <out-dir>", file=sys.stderr)
        return 2
    out = sys.argv[1]
    if not TOKEN_FILE:
        print("GITHUB_TOKEN_FILE is not set", file=sys.stderr)
        return 2
    with open(TOKEN_FILE) as fh:
        token = fh.read().strip()
    if not token:
        print("the GitHub token is empty", file=sys.stderr)
        return 1

    repos = safe("user/repos?per_page=100&affiliation=owner&sort=pushed",
                 token, [])
    notes = safe("notifications?per_page=100", token, [])

    def search(kind):
        q = urllib.parse.quote(f"is:open is:{kind} involves:{USER}")
        return safe(f"search/issues?q={q}&per_page={WORK_ROWS}", token, {})

    issues = search("issue")
    prs = search("pr")

    # CI failures are the bulk of the notifications, and the only part of them
    # that is actionable. Everything else is counted, not listed.
    ci = [n for n in notes if n.get("reason") == "ci_activity"]
    alerts = [n for n in notes if n.get("reason") != "ci_activity"]

    def repo_of(n):
        return (n.get("repository") or {}).get("name", "?")

    # one row per repo, not per run: eight failures of the same workflow say
    # the same thing eight times and crowd out the other repos.
    by_repo = {}
    for n in ci:
        r = repo_of(n)
        e = by_repo.setdefault(r, {"name": r, "n": 0, "last": "", "what": ""})
        e["n"] += 1
        u = n.get("updated_at", "")
        if u > e["last"]:
            e["last"] = u
            title = n.get("subject", {}).get("title", "")
            e["what"] = title.split(" workflow run")[0][:22]
    ci_rows = sorted(by_repo.values(), key=lambda e: (-e["n"], e["name"]))[:CI_ROWS]
    for e in ci_rows:
        e["age"] = ago(e["last"])

    active = [{
        "name": r["name"][:20],
        "lang": (r.get("language") or "-")[:8],
        "stars": r.get("stargazers_count", 0),
        "age": ago(r.get("pushed_at")),
    } for r in repos[:REPO_ROWS]]

    work = []
    for kind, res in (("issue", issues), ("pr", prs)):
        for i in (res.get("items") or [])[:WORK_ROWS]:
            work.append({
                "kind": kind,
                "repo": i.get("repository_url", "").rsplit("/", 1)[-1][:14],
                "title": (i.get("title") or "")[:34],
                "age": ago(i.get("created_at")),
            })
    work = work[:WORK_ROWS]

    # Languages, counted off the repo list rather than fetched: /languages is
    # one call per repo and this says the same thing for free. It exists to
    # give the side column something true to show, because with no open issues
    # or PRs it was 280px of white.
    langs = {}
    for r in repos:
        lang = r.get("language")
        if lang:
            langs[lang] = langs.get(lang, 0) + 1
    ranked = sorted(langs.items(), key=lambda kv: (-kv[1], kv[0]))[:LANG_ROWS]
    top = ranked[0][1] if ranked else 1
    # share of the leader, not of the total: a share of the total makes
    # everything under the top language a sliver on a 46px bar.
    top_langs = [{"name": k, "n": v, "pct": round(100 * v / top)}
                 for k, v in ranked]

    # Liquid cannot slice, so the two sub-columns are split here.
    half = (len(active) + 1) // 2

    payload = {
        "generated": datetime.now(timezone.utc).strftime("%H:%M"),
        "user": USER,
        "commits7": commits(token, 7),
        "commits30": commits(token, 30),
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
        # an empty work list is the normal state here, and the panel says so
        # rather than leaving a blank box that reads as a broken feed.
        "langs": top_langs,
        "work_empty": not work,
    }

    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "github.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh)
    os.replace(tmp, path)
    print(f"github: {payload['commits7']} commits/7d, {len(repos)} repos, "
          f"{len(by_repo)} repos with failing CI, {payload['issues']} issues, "
          f"{payload['prs']} PRs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
