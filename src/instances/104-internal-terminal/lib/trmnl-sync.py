"""Push the repo's TRMNL templates to the plugins; no-op if unchanged.

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
# rate-limited: six back-to-back pushes hit 429
PUSH_INTERVAL_S = float(os.environ.get("TRMNL_PUSH_INTERVAL", "12"))
TIMEOUT_S = 40
# cloudflare 403s urllib's default user agent
USER_AGENT = "homelab-trmnl-sync/1.0 (+https://lsck0.dev)"


def markup_path(plugin_id):
    return f"/{plugin_id}/markup/markup_full"


def call(path, token, body=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def current(plugin_id, token):
    """The markup the plugin has now, or None if it cannot be read."""
    try:
        body = call(markup_path(plugin_id), token)
    except (urllib.error.URLError, ValueError) as e:
        print(f"{plugin_id}: could not read the current markup: {e}", file=sys.stderr)
        return None
    # fresh plugins return 200 with no markup
    return (body or {}).get("data", {}).get("markup") or ""


def main():
    pairs = sys.argv[1:]
    if not pairs:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
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

        # space only between writes
        if pushed:
            time.sleep(PUSH_INTERVAL_S)
        try:
            call(markup_path(plugin_id), token, {"content": want}, method="PUT")
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
