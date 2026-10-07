"""An app's own Grafana dashboards, taken from the commit being deployed, made safe to provision.

Usage: dashboards-import.py <app> <checkout> <out root> <glob>...   (app-builder, after a deploy succeeded)

Every file the app's `telemetry.dashboards` globs match in the checkout is normalised and written to
<out root>/<app>/, which replaces the folder's previous content whole; vm-105's grafana provisions that folder read
only as the app's folder. Normalised: the uid is prefixed with the app (two apps never collide), every datasource
reference points at the app's own datasources (its loki, tempo and pyroscope tenants, the shared prometheus, where
an app's series carry its `app` label), and a reference to anything else refuses the file. A refusal names the file
and the reason and exits 2; the deploy itself stands, the previous dashboards stay.
"""
import glob
import json
import os
import shutil
import sys
import tempfile

# ---- constants ----------------------------------------------------------------------------------

DASHBOARD_BYTES_MAX = 1024 * 1024
DASHBOARDS_MAX = 20
# grafana's own limit on a dashboard uid
UID_LENGTH_MAX = 40
# datasource type -> the app's datasource uid ("{app}" filled in)
DATASOURCES = {"prometheus": "prometheus", "loki": "loki-{app}", "tempo": "tempo-{app}",
               "grafana-pyroscope-datasource": "pyroscope-{app}"}
# a datasource named instead of referenced: its default name -> its type
NAMES = {"prometheus": "prometheus", "loki": "loki", "tempo": "tempo", "pyroscope": "grafana-pyroscope-datasource"}
# grafana's built-in pseudo datasources: annotations, mixed panels, dashboard reuse
BUILTIN = {"grafana", "-- Grafana --", "-- Mixed --", "-- Dashboard --", "datasource"}


class Refused(Exception):
    pass


# ---- functions ----------------------------------------------------------------------------------

def datasource_rewrite(ref, app, inputs):
    """The app's own datasource for one reference, or Refused."""
    if isinstance(ref, dict):
        if ref.get("type") in BUILTIN or ref.get("uid") in BUILTIN:
            return ref
        kind = ref.get("type")
    elif isinstance(ref, str):
        if ref in BUILTIN:
            return ref
        variable = ref[2:-1] if ref.startswith("${") and ref.endswith("}") else ref[1:] if ref.startswith("$") else None
        if variable in inputs:
            kind = inputs[variable]
        elif variable is not None:
            # a dashboard variable chooses at view time; datasource variables list only the app's own (node_rewrite)
            return ref
        else:
            kind = NAMES.get(ref.lower())
    else:
        raise Refused(f"datasource {ref!r} is neither a name nor a reference")
    if kind not in DATASOURCES:
        raise Refused(f"datasource {ref!r}: only {', '.join(sorted(DATASOURCES))}")
    return {"type": kind, "uid": DATASOURCES[kind].format(app=app)}


def node_rewrite(node, app, inputs):
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            out[key] = datasource_rewrite(value, app, inputs) if key == "datasource" else node_rewrite(value, app, inputs)
        if out.get("type") == "datasource" and "query" in out:
            # a datasource variable lists only the app's own of that type
            kind = out["query"]
            if kind not in DATASOURCES:
                raise Refused(f"datasource variable of type {kind!r}")
            out["regex"] = f"^{DATASOURCES[kind].format(app=app)}$"
        return out
    if isinstance(node, list):
        return [node_rewrite(v, app, inputs) for v in node]
    return node


def dashboard_normalise(app, name, text):
    """The dashboard as the app's, or Refused naming why."""
    if len(text) > DASHBOARD_BYTES_MAX:
        raise Refused(f"larger than {DASHBOARD_BYTES_MAX} bytes")
    try:
        board = json.loads(text)
    except json.JSONDecodeError as e:
        raise Refused(f"not json: {e}") from None
    if not isinstance(board, dict) or not isinstance(board.get("panels", []), list):
        raise Refused("not a dashboard")
    # grafana's export form: ${DS_X} placeholders described in __inputs
    inputs = {i["name"]: i.get("pluginId") for i in board.pop("__inputs", []) if isinstance(i, dict) and "name" in i}
    board.pop("__requires", None)
    board.pop("id", None)
    board = node_rewrite(board, app, inputs)
    stem = os.path.splitext(os.path.basename(name))[0]
    board["uid"] = f"{app}-{board.get('uid') or stem}"[:UID_LENGTH_MAX]
    return board


def dashboards_import(app, checkout, out_root, patterns):
    """Normalise every matched file into a fresh folder, then swap it in; nothing changes on a refusal."""
    root = os.path.realpath(checkout)
    files = sorted({f for p in patterns for f in glob.glob(os.path.join(root, p), recursive=True)})
    if len(files) > DASHBOARDS_MAX:
        raise Refused(f"{len(files)} files, more than {DASHBOARDS_MAX}")
    boards = {}
    for path in files:
        rel = os.path.relpath(os.path.realpath(path), root)
        if rel.startswith(".."):
            raise Refused(f"{rel}: outside the checkout")
        with open(path, encoding="utf-8") as f:
            try:
                board = dashboard_normalise(app, rel, f.read(DASHBOARD_BYTES_MAX + 1))
            except Refused as e:
                raise Refused(f"{rel}: {e}") from None
        if board["uid"] in boards:
            raise Refused(f"{rel}: uid {board['uid']} twice")
        boards[board["uid"]] = board
    os.makedirs(out_root, exist_ok=True)
    # staged beside the provisioned root, never inside it, then swapped in by one rename on the same filesystem
    staging = tempfile.mkdtemp(dir=os.path.dirname(os.path.abspath(out_root)), prefix=f"{app}.")
    for uid, board in boards.items():
        with open(os.path.join(staging, f"{uid}.json"), "w", encoding="utf-8") as f:
            json.dump(board, f)
    target = os.path.join(out_root, app)
    if os.path.exists(target):
        shutil.rmtree(target)
    os.rename(staging, target)
    os.chmod(target, 0o755)
    return sorted(boards)


def main():
    if len(sys.argv) < 4:
        print("usage: dashboards-import.py <app> <checkout> <out root> <glob>...", file=sys.stderr)
        return 2
    app, checkout, out_root, patterns = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    try:
        uids = dashboards_import(app, checkout, out_root, patterns)
    except Refused as e:
        print(f"dashboards-import: {app}: refused: {e}", file=sys.stderr)
        return 2
    print(f"dashboards-import: {app}: {len(uids)} dashboard(s): {' '.join(uids)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
