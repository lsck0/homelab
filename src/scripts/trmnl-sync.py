"""Push the TRMNL dashboard templates from this repo to the plugins.

The .liquid files under src/modules/trmnl are the dashboards, and until this
existed nothing carried them anywhere: every change was uploaded by hand with
curl. So the repo held the source of truth for how the panels look and the
panels held whatever had last been pasted into them - the one place in the lab
where a service's visible behaviour lived outside git.

Reconciles rather than pushes: TRMNL will hand back the markup a plugin
currently has, so a run that changes nothing sends nothing. That matters more
than saving a request - a push is rate-limited, and pushing six templates that
were already correct is how a run ends in 429.

Usage: trmnl-sync.py <id>=<path> [<id>=<path> ...]
The key comes from TRMNL_API_KEY_FILE.
"""
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

BASE = "https://trmnl.com/api/plugin_settings"
# TRMNL rate-limits writes; six back-to-back pushes answered 429 when these
# were uploaded by hand. Only paid on a template that actually changed.
PUSH_INTERVAL = float(os.environ.get("TRMNL_PUSH_INTERVAL", "12"))
TIMEOUT = 40


def call(path, token, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    # TRMNL is behind Cloudflare, which refuses urllib's default agent with a
    # bare 403 - the same request through curl is fine. Identify properly.
    req.add_header("User-Agent", "homelab-trmnl-sync/1.0 (+https://lsck0.dev)")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def current(plugin_id, token):
    """The markup the plugin has now, or None if it cannot be read."""
    try:
        body = call(f"/{plugin_id}/markup/markup_full", token)
    except (urllib.error.URLError, ValueError) as e:
        print(f"{plugin_id}: could not read the current markup: {e}", file=sys.stderr)
        return None
    return (body or {}).get("data", {}).get("markup")


def main():
    pairs = sys.argv[1:]
    if not pairs:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2

    key_file = os.environ.get("TRMNL_API_KEY_FILE")
    if not key_file:
        print("TRMNL_API_KEY_FILE is not set", file=sys.stderr)
        return 2
    token = pathlib.Path(key_file).read_text().strip()
    if not token:
        print("the TRMNL API key is empty", file=sys.stderr)
        return 1

    pushed = unchanged = failed = 0
    for pair in pairs:
        plugin_id, _, path = pair.partition("=")
        want = pathlib.Path(path).read_text()

        have = current(plugin_id, token)
        if have is None:
            failed += 1
            continue
        if have == want:
            unchanged += 1
            continue

        # spacing only between writes, so a run with one change is not slow
        if pushed:
            time.sleep(PUSH_INTERVAL)
        try:
            call(f"/{plugin_id}/markup/markup_full", token,
                 {"content": want}, method="PUT")
        except (urllib.error.URLError, ValueError) as e:
            print(f"{plugin_id}: push failed: {e}", file=sys.stderr)
            failed += 1
            continue
        print(f"{plugin_id}: updated from {pathlib.Path(path).name}")
        pushed += 1

    print(f"pushed={pushed} unchanged={unchanged} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
