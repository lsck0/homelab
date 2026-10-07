#!/usr/bin/env bash
# fill hermes (vm-114) secrets, then run ./sync.sh
#
# usage: hermes-secrets.sh [--force]   (--force regenerates the ssh key and the github app, and asks again)
set -euo pipefail

HERMES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$HERMES_DIR/../../.." && pwd)"
SRC="$ROOT_DIR/src"
PUB="$SRC/lab/keys/hermes.pub"
APP_JSON="$HERMES_DIR/lib/github-app.json"
HERMES_ID=114
RULESET_NAME="protect-master"
# the manifest flow waits this long for the owner to create the app in the browser
APP_CREATE_TIMEOUT_S=900
# then up to 15 minutes for the owner to install it on the repo
APP_INSTALL_ATTEMPTS=180
APP_INSTALL_RETRY_S=5
# github's built-in repository role "admin"; its id is fixed by the rulesets api, not looked up per repo
REPOSITORY_ROLE_ADMIN_ID=5
export SOPS_AGE_KEY_FILE="$ROOT_DIR/secrets/age.txt"
usage() { echo "usage: hermes-secrets.sh [--force]" >&2; exit 2; }
[ $# -le 1 ] || usage
case "${1:-}" in
  "") FORCE="" ;;
  --force) FORCE=--force ;;
  *) usage ;;
esac

# shellcheck source=src/scripts/lib/tools.sh
. "$SRC/scripts/lib/tools.sh"
# shellcheck source=src/scripts/lib/secrets.sh
. "$SRC/scripts/lib/secrets.sh"
tools_require sops jq ssh-keygen gh python3 openssl curl nix
# this repository on github (src/generated/site.json, written by init.sh)
REPO=$(jq -r .repo "$SRC/generated/site.json")

# a secret not set yet reads as empty
current() { secrets_get "$1" 2>/dev/null || true; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# -----------------------------------------------------------------------------
# SSH KEY (LAB)
# -----------------------------------------------------------------------------
if [ -z "$(current hermes-ssh-key)" ] || [ "$FORCE" = --force ] || [ ! -f "$PUB" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hermes@vm-114" -f "$tmp/lab"
  secrets_set hermes-ssh-key "$(cat "$tmp/lab")"
  # hermes may log in from its own vm and through the router only
  printf 'from="%s,%s" %s\n' "$(nix eval --raw --no-warn-dirty "$SRC#lab.inventory.\"$HERMES_ID\".ip")" \
    "$(jq -r .lan.router "$SRC/generated/site.json")" "$(cat "$tmp/lab.pub")" > "$PUB"
  git -C "$ROOT_DIR" add "$PUB"
  echo ">>> hermes-ssh-key generated, public key in src/lab/keys/hermes.pub"
else
  echo ">>> hermes-ssh-key already set"
fi

# -----------------------------------------------------------------------------
# GITHUB APP (PULL REQUESTS)
# -----------------------------------------------------------------------------
if [ -z "$(current hermes-github-app-key)" ] || [ ! -f "$APP_JSON" ] || [ "$FORCE" = --force ]; then
  # manifest flow: a local page posts the manifest to github, the owner confirms there
  python3 - "$REPO" "$tmp/app.json" "$APP_CREATE_TIMEOUT_S" <<'PY'
import html, http.server, json, secrets, subprocess, sys, time, urllib.parse, urllib.request
repo, out, timeout_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
state = secrets.token_urlsafe(24)
manifest = {
    "name": f"{repo.replace('/', '-')}-hermes",
    "url": f"https://github.com/{repo}",
    "hook_attributes": {"url": f"https://github.com/{repo}", "active": False},
    "public": False,
    "default_permissions": {"contents": "write", "pull_requests": "write", "metadata": "read"},
    "default_events": [],
}
done = False
class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body, location=None):
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        global done
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            return self.reply(200, f"""<form method="post" action="https://github.com/settings/apps/new?state={state}">
<input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest))}"></form>
<script>document.forms[0].submit()</script>""")
        if url.path != "/created" or query.get("state") != [state] or "code" not in query:
            return self.reply(400, "unexpected request")
        request = urllib.request.Request(f"https://api.github.com/app-manifests/{query['code'][0]}/conversions",
                                         method="POST", headers={"Accept": "application/vnd.github+json"})
        app = json.load(urllib.request.urlopen(request))
        with open(out, "w") as f:
            json.dump({"id": app["id"], "slug": app["slug"], "pem": app["pem"]}, f)
        done = True
        self.reply(302, "", f"https://github.com/apps/{app['slug']}/installations/new")
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
base = f"http://127.0.0.1:{server.server_address[1]}"
manifest["redirect_url"] = f"{base}/created"
print(f">>> Open {base}/ , create the app, then install it on {repo} only", flush=True)
subprocess.run(["xdg-open", f"{base}/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
deadline = time.monotonic() + timeout_s
while not done:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        sys.exit(f"no app created within {timeout_s} s; rerun to try again")
    # one request at a time, never past the deadline
    server.timeout = remaining
    server.handle_request()
PY
  secrets_set hermes-github-app-key "$(jq -r .pem "$tmp/app.json")"
  jq '{id, slug}' "$tmp/app.json" > "$APP_JSON"
  git -C "$ROOT_DIR" add "$APP_JSON"
  echo ">>> GitHub App $(jq -r .slug "$APP_JSON") created"
fi

{ current hermes-github-app-key; echo; } > "$tmp/app.pem"; chmod 600 "$tmp/app.pem"
for i in $(seq 1 "$APP_INSTALL_ATTEMPTS"); do
  "$HERMES_DIR/lib/github-app-token.sh" "$(jq -r .id "$APP_JSON")" "$tmp/app.pem" "$REPO" > "$tmp/token" 2>/dev/null && break
  [ "$i" != 1 ] || echo ">>> waiting for the app to be installed on $REPO: https://github.com/apps/$(jq -r .slug "$APP_JSON")/installations/new"
  [ "$i" != "$APP_INSTALL_ATTEMPTS" ] || { echo "ERROR: app not installed on $REPO"; exit 1; }
  sleep "$APP_INSTALL_RETRY_S"
done
selection=$(curl -sf -H "Authorization: Bearer $(cat "$tmp/token")" https://api.github.com/installation/repositories \
  | jq -r '[.repositories[].full_name] | join(" ")')
[ "$selection" = "$REPO" ] || echo "WARNING: the app can reach $selection; limit its installation to $REPO"
echo ">>> GitHub App installed on $REPO"

# master: only repo admins may update or delete
ruleset=$(jq -n --arg name "$RULESET_NAME" --argjson admin "$REPOSITORY_ROLE_ADMIN_ID" '{
  name: $name, target: "branch", enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  rules: [ { type: "update" }, { type: "deletion" }, { type: "non_fast_forward" } ],
  bypass_actors: [ { actor_id: $admin, actor_type: "RepositoryRole", bypass_mode: "always" } ]
}')
id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")
if [ -n "$id" ]; then
  gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<< "$ruleset" >/dev/null
else
  gh api -X POST "repos/$REPO/rulesets" --input - <<< "$ruleset" >/dev/null
fi
echo ">>> ruleset $RULESET_NAME active"

# -----------------------------------------------------------------------------
# PROMPTED
# -----------------------------------------------------------------------------
# ask <name> <prompt>
ask() {
  if [ -n "$(current "$1")" ] && [ "$FORCE" != --force ]; then
    echo ">>> $1 already set"; return
  fi
  if [ ! -t 0 ]; then
    echo ">>> $1 missing: run this script in a terminal to enter it"; return
  fi
  read -r -s -p "$2: " value; echo
  [ -n "$value" ] || { echo "ERROR: $1 must not be empty."; exit 1; }
  secrets_set "$1" "$value"
  echo ">>> $1 saved"
}

ask telegram-bot-token "Telegram bot token (from @BotFather)"
ask telegram-chat-id   "Your Telegram user id (numeric)"

echo ">>> Done. Run ./sync.sh to deploy Hermes."
