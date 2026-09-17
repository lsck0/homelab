#!/bin/bash
# Fill the secrets Hermes (vm-113) needs, then run ./sync.sh.
#
#   hermes-ssh-key       generated here, public key goes to src/modules/hermes.pub
#                        (root on every VM and the Proxmox host)
#   hermes-github-app-key  private key of the GitHub App Hermes uses to push
#                        hermes/* branches and open pull requests; created here
#                        in your browser (app id in src/modules/hermes/github-app.json)
#   hermes-llm-api-key   Anthropic API key (prompted)
#   telegram-bot-token   from @BotFather (prompted if empty)
#   telegram-chat-id     your numeric Telegram user id (prompted if empty;
#                        message @userinfobot to get it)
#
# The GitHub side needs `gh` logged in as the repo owner and a browser. The app
# may write contents and pull requests but not workflows. A deploy key would not
# do: on a personal repo it bypasses every ruleset, so Hermes could push master.
# The protect-master ruleset lets only repo admins update master, which the
# app is not.
#
# Existing non-empty values are kept. Pass --force to re-enter them. Without a
# terminal the prompted secrets are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS="$ROOT_DIR/src/secrets.json"
PUB="$ROOT_DIR/src/modules/hermes.pub"
REPO="lsck0/homelab"
export SOPS_AGE_KEY_FILE="$ROOT_DIR/secrets/age.txt"
FORCE="${1:-}"

for tool in sops jq ssh-keygen gh python3 openssl curl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required."; exit 1; }
done

current() { sops -d --extract "[\"$1\"]" "$SECRETS" 2>/dev/null || true; }
put() { sops set "$SECRETS" "[\"$1\"]" "$(jq -Rs . <<< "$2" | sed 's/\\n"$/"/')"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# SSH KEY (LAB)
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$(current hermes-ssh-key)" ] || [ "$FORCE" = --force ] || [ ! -f "$PUB" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hermes@vm-113" -f "$tmp/lab"
  put hermes-ssh-key "$(cat "$tmp/lab")"
  cp "$tmp/lab.pub" "$PUB"
  git -C "$ROOT_DIR" add "$PUB"
  echo ">>> hermes-ssh-key generated, public key in src/modules/hermes.pub"
else
  echo ">>> hermes-ssh-key already set"
fi

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB APP (PULL REQUESTS)
# ─────────────────────────────────────────────────────────────────────────────
APP_JSON="$ROOT_DIR/src/modules/hermes/github-app.json"
if [ -z "$(current hermes-github-app-key)" ] || [ ! -f "$APP_JSON" ] || [ "$FORCE" = --force ]; then
  # manifest flow: a local page posts the manifest to GitHub, you confirm, and
  # GitHub redirects back here with a code that converts into the app's key.
  python3 - "$REPO" "$tmp/app.json" <<'PY'
import html, http.server, json, secrets, subprocess, sys, urllib.parse, urllib.request
repo, out = sys.argv[1], sys.argv[2]
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
        if location: self.send_header("Location", location)
        self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(body.encode())
    def do_GET(self):
        global done
        url = urllib.parse.urlparse(self.path); query = urllib.parse.parse_qs(url.query)
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
server.timeout = 900
while not done:
    server.handle_request()
PY
  put hermes-github-app-key "$(jq -r .pem "$tmp/app.json")"
  jq '{id, slug}' "$tmp/app.json" > "$APP_JSON"
  git -C "$ROOT_DIR" add "$APP_JSON"
  echo ">>> GitHub App $(jq -r .slug "$APP_JSON") created"
fi

{ current hermes-github-app-key; echo; } > "$tmp/app.pem"; chmod 600 "$tmp/app.pem"
for i in $(seq 1 180); do
  "$SCRIPT_DIR/github-app-token.sh" "$(jq -r .id "$APP_JSON")" "$tmp/app.pem" "$REPO" > "$tmp/token" 2>/dev/null && break
  [ "$i" = 1 ] && echo ">>> waiting for the app to be installed on $REPO: https://github.com/apps/$(jq -r .slug "$APP_JSON")/installations/new"
  [ "$i" = 180 ] && { echo "ERROR: app not installed on $REPO"; exit 1; }
  sleep 5
done
selection=$(curl -sf -H "Authorization: Bearer $(cat "$tmp/token")" https://api.github.com/installation/repositories \
  | jq -r '[.repositories[].full_name] | join(" ")')
[ "$selection" = "$REPO" ] || echo "WARNING: the app can reach $selection; limit its installation to $REPO"
echo ">>> GitHub App installed on $REPO"

# master: only repo admins (the owner, sync.sh) may update or delete it
ruleset=$(jq -n '{
  name: "protect-master", target: "branch", enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  rules: [ { type: "update" }, { type: "deletion" }, { type: "non_fast_forward" } ],
  bypass_actors: [ { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" } ]
}')
id=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "protect-master") | .id')
if [ -n "$id" ]; then
  gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<< "$ruleset" >/dev/null
else
  gh api -X POST "repos/$REPO/rulesets" --input - <<< "$ruleset" >/dev/null
fi
echo ">>> ruleset protect-master active"

# ─────────────────────────────────────────────────────────────────────────────
# PROMPTED
# ─────────────────────────────────────────────────────────────────────────────
ask() { # name prompt
  if [ -n "$(current "$1")" ] && [ "$FORCE" != --force ]; then
    echo ">>> $1 already set"; return
  fi
  if [ ! -t 0 ]; then
    echo ">>> $1 missing: run this script in a terminal to enter it"; return
  fi
  read -r -s -p "$2: " value; echo
  [ -n "$value" ] || { echo "ERROR: $1 must not be empty."; exit 1; }
  put "$1" "$value"
  echo ">>> $1 saved"
}

ask hermes-llm-api-key "Anthropic API key (sk-ant-...)"
ask telegram-bot-token "Telegram bot token (from @BotFather)"
ask telegram-chat-id   "Your Telegram user id (numeric)"

echo ">>> Done. Run ./sync.sh to deploy Hermes."
