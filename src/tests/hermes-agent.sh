#!/usr/bin/env bash
# Hermes agent end-to-end test: free Nous model (nous/welcome), or the
# production Anthropic config when ANTHROPIC_API_KEY is set.
#
# Runs the exact Hermes package, settings, skills and AGENTS.md from the vm-113
# config, switched to the Nous free tier, inside a container (it executes shell
# commands without approval). The lab is simulated at its edges:
#   vm, ssh, nc, lab-token   shims that log every call and answer like the lab
#   curl                     rewrites lab IPs: Sonarr -> a real Sonarr container,
#                            Paperless/Firefly -> a recording mock API
#   telegram                 live: the real bot answers the owner (needs env,
#                            see the scenario)
# Each scenario is one chat turn, like a Telegram message, followed by checks on
# what the agent actually did.
#
#   GitHub                   lab-pr pushes to a local bare copy of this repo
# Usage: src/tests/hermes-agent.sh [scenario...]   (minecraft backup media bill repo | telegram)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${HERMES_TEST_SHELL:-}" ]; then
  exec nix shell --inputs-from "$SRC" nixpkgs#bash nixpkgs#jq nixpkgs#yq-go nixpkgs#coreutils \
    nixpkgs#gnugrep nixpkgs#gnused nixpkgs#curl nixpkgs#groff \
    -c env HERMES_TEST_SHELL=1 bash "${BASH_SOURCE[0]}" "$@"
fi

SCENARIOS=${*:-minecraft backup media bill repo}
W=$(mktemp -d /tmp/hermes-test.XXXXXX)
NET=hermestest
FAILED=0
cleanup() {
  docker rm -f ht-sonarr ht-mock ht-gateway >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ "${KEEP:-0}" = 1 ] && { echo ">>> KEEP=1: workdir $W"; return; }
  docker run --rm -v "$W:/w" alpine sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT
ok()   { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }

H=nixosConfigurations.113-internal-hermes.config.services.hermes-agent
echo ">>> Building Hermes (vm-113 package) and test tools"
ENV=$(nix build --no-warn-dirty --no-link --print-out-paths --impure --expr "
  let f = builtins.getFlake \"$SRC\"; pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  in pkgs.buildEnv { name = \"hermes-test-env\"; paths = [
    f.nixosConfigurations.\"113-internal-hermes\".config.services.hermes-agent.package pkgs.bashInteractive pkgs.coreutils pkgs.curl pkgs.jq pkgs.gnugrep pkgs.gnused
    pkgs.gawk pkgs.findutils pkgs.poppler-utils pkgs.python3 pkgs.procps pkgs.which pkgs.git pkgs.cacert ]; }")

mkdir -p "$W"/{home,workspace,shims,log,tokens,mock}; : > "$W/home/.env"
chmod -R 777 "$W"

# ─────────────────────────────────────────────────────────────────────────────
# HERMES CONFIG
# ─────────────────────────────────────────────────────────────────────────────
# vm-113 settings, model switched to the Nous free tier
# With ANTHROPIC_API_KEY set, test the production model config unchanged;
# otherwise the free Nous tier. The local Ollama fallback is not available here.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  MODEL_FILTER='.'
  printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$W/home/.env"; chmod 600 "$W/home/.env"
  echo ">>> Model: production config (Anthropic)"
else
  MODEL_FILTER='.model = {provider: "nous", default: "nous/welcome"}'
  echo ">>> Model: Nous free tier (nous/welcome)"
fi
nix eval --no-warn-dirty --json "$SRC#$H.settings" \
  | jq "$MODEL_FILTER | del(.fallback_model) | .terminal.cwd = \"/work/workspace\"" \
  | yq -P > "$W/home/config.yaml"
nix eval --no-warn-dirty --raw "$SRC#$H.documents.\"AGENTS.md\"" > "$W/workspace/AGENTS.md"
mkdir -p "$W/home/skills/homelab"
cp -r "$SRC/modules/hermes/skills/." "$W/home/skills/homelab/"
echo ">>> config.yaml:"; sed 's/^/    /' "$W/home/config.yaml"

# the free tier mints a guest identity per fresh HERMES_HOME and rate-limits
# minting; reuse one across runs.
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/homelab-hermes-test
mkdir -p "$CACHE"; chmod 700 "$CACHE"
[ -f "$CACHE/auth.json" ] && cp "$CACHE/auth.json" "$W/home/auth.json"
save_identity() { [ -s "$W/home/auth.json" ] && cp "$W/home/auth.json" "$CACHE/auth.json"; true; }

# ─────────────────────────────────────────────────────────────────────────────
# LAB SHIMS
# ─────────────────────────────────────────────────────────────────────────────
cat > "$W/shims/_log" <<'EOF'
#!/bin/sh
printf '%s\t%s\n' "$(date +%s)" "$*" >> /work/log/calls.log
EOF
cat > "$W/shims/vm" <<'EOF'
#!/bin/sh
/work/shims/_log vm "$@"
case "$1" in
  list|"") printf '106\trunning\t106-internal-kopia\n120\trunning\t120-internal-paperless\n123\tstopped\t123-internal-firefly\n208\tstopped\t208-external-minecraft\n' ;;
  status) echo running ;;
  start) echo "vm-$2 up" ;;
  stop) echo "vm-$2 shutting down" ;;
  reboot) echo "vm-$2 rebooting" ;;
esac
EOF
cat > "$W/shims/ssh" <<'EOF'
#!/bin/bash
export PATH="@ENVBIN@:$PATH"   # coreutils date, not whatever the agent's shell has
# ssh [opts] host command...
args=("$@"); while [[ "${args[0]}" == -* ]]; do
  case "${args[0]}" in -o|-i|-p|-l|-F) args=("${args[@]:2}") ;; *) args=("${args[@]:1}") ;; esac
done
host=${args[0]#root@}; cmd="${args[*]:1}"
/work/shims/_log ssh "$host" "$cmd"
case "$host:$cmd" in
  10.200.0.208:*mc-modpack\ http*|10.200.0.208:*mc-modpack\ [a-z]*)
    echo ">>> modpack set to ${cmd##*mc-modpack }, restarting server (first start downloads the pack)" ;;
  10.200.0.208:*mc-modpack*) printf 'current:\nTYPE=MODRINTH\nMODRINTH_MODPACK=https://modrinth.com/modpack/cobbleverse\nVERSION=LATEST\nLEVEL=world\n' ;;
  10.200.0.208:*podman\ logs*|10.200.0.208:*journalctl*) echo '[Server thread/INFO]: Done (41.237s)! For help, type "help"' ;;
  10.200.0.208:*mc-rcon*list*) echo "There are 0 of a max of 42069 players online:" ;;
  10.100.0.106:*nas-restore\ list*|10.100.0.106:*kopia*snapshot\ list*)
    [ -f /work/log/snapshots ] || for d in 3 2 1 0; do
      printf '%s  %s 02:00 CEST  files:%s\n' "$(printf 'snap%028d' "$d")" "$(date -d "$d days ago" +%F)" "8130$d"
    done > /work/log/snapshots
    cat /work/log/snapshots ;;
  10.100.0.106:*nas-restore\ now*)
    id=$(printf 'safe%028d' "$(date +%s)")
    printf '%s  %s CEST  files:81401\n' "$id" "$(date '+%F %H:%M')" >> /work/log/snapshots
    echo "Created snapshot with ID $id" ;;
  10.100.0.106:*nas-restore\ service*) echo ">>> done: /srv/nas/data/paperless restored" ;;
  10.100.0.106:*ls*data*) printf 'authelia\nfirefly\nforgejo\nminecraft\npaperless\nsonarr\n' ;;
  *) echo "ok" ;;
esac
EOF
cat > "$W/shims/nc" <<'EOF'
#!/bin/sh
/work/shims/_log nc "$@"; exit 0
EOF
cat > "$W/shims/lab-token" <<'EOF'
#!/bin/sh
/work/shims/_log lab-token "$@"
[ -z "$1" ] && { ls /work/tokens | sed 's/\.token$//'; exit 0; }
cat "/work/tokens/$1.token"
EOF
# curl: lab IPs -> test backends, everything else untouched.
cat > "$W/shims/curl" <<'EOF'
#!/bin/bash
out=()
for a in "$@"; do
  a=${a//http:\/\/10.100.0.130:80/http://sonarr:8989}
  a=${a//http:\/\/10.100.0.130/http://sonarr:8989}
  a=${a//http:\/\/10.100.0.120:8080/http://mock:8000/paperless}
  a=${a//http:\/\/10.100.0.123:8080/http://mock:8000/firefly}
  out+=("$a")
done
case "$*" in *10.100.0.*|*10.200.0.*) /work/shims/_log curl "$@" ;; esac
exec @CURL@ "${out[@]}"
EOF
sed -i "s|@CURL@|$ENV/bin/curl|" "$W/shims/curl"
sed -i "s|@ENVBIN@|$ENV/bin|" "$W/shims/ssh"
chmod +x "$W"/shims/*
echo -n fake-paperless-token > "$W/tokens/paperless-key.token"
echo -n fake-firefly-token > "$W/tokens/firefly-token.token"

# the repo: a bare copy stands in for GitHub; lab-pr pushes there and answers
# with a fake pull request URL. Git identity as configured on vm-113.
git clone -q --bare --no-local "$SRC/.." "$W/remote.git"   # a copy: chmod below must not touch this repo
MASTER=$(git -C "$W/remote.git" rev-parse master)
nix eval --no-warn-dirty --json "$SRC#nixosConfigurations.113-internal-hermes.config.programs.git.config" \
  | jq -r 'map(.user // empty) | add | "[user]\n\tname = \(.name)\n\temail = \(.email)"' > "$W/home/.gitconfig"
printf '[url "/work/remote.git"]\n\tinsteadOf = https://github.com/lsck0/homelab.git\n[safe]\n\tdirectory = *\n' >> "$W/home/.gitconfig"
cat > "$W/shims/lab-pr" <<'EOF'
#!/bin/sh
/work/shims/_log lab-pr "$(git symbolic-ref --short HEAD)"
git push -q -u origin HEAD && echo "pull request: https://github.com/lsck0/homelab/pull/99"
EOF
chmod -R 777 "$W/remote.git"; chmod +x "$W/shims/lab-pr"

# ─────────────────────────────────────────────────────────────────────────────
# RECORDING MOCK FOR PAPERLESS + FIREFLY
# ─────────────────────────────────────────────────────────────────────────────
cat > "$W/mock/mock.py" <<'EOF'
import json, http.server, uuid
LOG = "/work/log/mock.jsonl"
class H(http.server.BaseHTTPRequestHandler):
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _log(self, body):
        text = body.decode("utf-8", "replace")
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": text[:4000]}) + "\n")
    def do_GET(self):
        self._log(b""); p = self.path
        if p.startswith("/paperless/api/tasks"):
            return self._send([{"task_id": "t1", "status": "SUCCESS", "related_document": "42"}])
        if p.startswith("/paperless/api/documents/42"):
            return self._send({"id": 42, "title": "bill"})
        if p.startswith("/firefly/api/v1/accounts"):
            return self._send({"data": [{"id": "1", "type": "accounts", "attributes": {"name": "Girokonto", "type": "asset", "current_balance": "1234.56", "currency_code": "EUR", "active": True}}]})
        if p.startswith("/firefly/api/v1/about") or p == "/firefly/" or p.startswith("/firefly/api"):
            return self._send({"data": {"version": "6.3.0"}})
        return self._send({})
    def do_POST(self):
        body = self._body(); self._log(body); p = self.path
        if p.startswith("/paperless/api/documents/post_document"):
            return self._send(str(uuid.uuid4()))
        if p.startswith("/firefly/api/v1/transactions"):
            return self._send({"data": {"id": "77", "type": "transactions", "attributes": {"transactions": []}}})
        return self._send({})
    do_PATCH = do_PUT = do_POST
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
EOF

docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
docker rm -f ht-mock >/dev/null 2>&1 || true
docker run -d --name ht-mock --network "$NET" --network-alias mock -v /nix/store:/nix/store:ro -v "$W:/work" \
  alpine "$ENV/bin/python3" /work/mock/mock.py >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# REAL SONARR FOR THE MEDIA SCENARIO
# ─────────────────────────────────────────────────────────────────────────────
if [[ " $SCENARIOS " == *" media "* ]]; then
  echo ">>> Starting Sonarr"
  mkdir -p "$W/sonarr" "$W/media/tv" "$W/media/anime"; chmod -R 777 "$W/sonarr" "$W/media"
  docker run -d --name ht-sonarr --network "$NET" --network-alias sonarr -p 127.0.0.1:28989:8989 \
    -e PUID=1000 -e PGID=1000 -v "$W/sonarr:/config" -v "$W/media:/data/media" \
    "$(nix eval --no-warn-dirty --raw "$SRC#nixosConfigurations.130-internal-sonarr.config.virtualisation.oci-containers.containers.sonarr.image")" >/dev/null
  for _ in $(seq 90); do [ -f "$W/sonarr/config.xml" ] && grep -q ApiKey "$W/sonarr/config.xml" && break; sleep 2; done
  SK=$(grep -oP '<ApiKey>\K[^<]+' "$W/sonarr/config.xml"); echo -n "$SK" > "$W/tokens/sonarr-key.token"
  for _ in $(seq 60); do curl -sf -H "X-Api-Key: $SK" http://127.0.0.1:28989/api/v3/system/status >/dev/null && break; sleep 2; done
  for p in /data/media/tv /data/media/anime; do
    curl -sf -X POST -H "X-Api-Key: $SK" -H "Content-Type: application/json" -d "{\"path\":\"$p\"}" http://127.0.0.1:28989/api/v3/rootfolder >/dev/null
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# AGENT RUNNER
# ─────────────────────────────────────────────────────────────────────────────
ask() { # ask <scenario> <prompt> [extra hermes args]
  local name=$1 prompt=$2; shift 2
  echo ">>> [$name] owner: $prompt"
  : > "$W/log/calls.log"; : > "$W/log/mock.jsonl"
  docker run --rm --user "$(id -u):$(id -g)" --network "$NET" -v /nix/store:/nix/store:ro -v "$W:/work" \
    -v "$ENV/bin/bash:/bin/bash:ro" -w /work/workspace \
    -e HOME=/work/home -e HERMES_HOME=/work/home -e HERMES_GUEST_ONBOARDING=1 \
    -e SSL_CERT_FILE="$ENV/etc/ssl/certs/ca-bundle.crt" \
    -e PATH="/work/shims:$ENV/bin" \
    alpine timeout 900 hermes chat -Q --yolo --max-turns 60 -q "$prompt" "$@" \
    > "$W/log/$name.out" 2>&1 || true
  save_identity
  if grep -qE "not logged into Nous Portal|not connected to any AI provider" "$W/log/$name.out"; then
    echo "    ERROR: no model available: $(grep -rhE 'free tier not set up' "$W"/home/logs/*.log 2>/dev/null | tail -1 | cut -d' ' -f5-)"
    echo ">>> Aborting: every retry extends the free-tier rate limit. Try later or set ANTHROPIC_API_KEY."
    exit 2
  fi
  echo "    hermes: $(grep -v '^session_id' "$W/log/$name.out" | tail -n 8 | sed 's/^/    | /' | sed '1s/^    | //')"
  echo "    lab calls:"; cut -f2- "$W/log/calls.log" | sed 's/^/      /' | head -40
  cp "$W/log/calls.log" "$W/log/$name.calls"; cp "$W/log/mock.jsonl" "$W/log/$name.mock"
}
called() { cut -f2- "$W/log/calls.log" | grep -qE "$1"; }
line_of() { cut -f2- "$W/log/calls.log" | grep -nE "$1" | head -1 | cut -d: -f1; }

for s in $SCENARIOS; do
  case "$s" in
  minecraft)
    ask minecraft "Start the minecraft server with the Adrenaserver modpack please"
    called 'vm start 208|curl .*qemu/208/status/start' && ok "minecraft: VM 208 started" || fail "minecraft: VM 208 not started"
    called 'ssh 10\.200\.0\.208 .*mc-modpack .*adrenaserver' && ok "minecraft: mc-modpack called with the pack" || fail "minecraft: mc-modpack not called with the pack"
    ;;
  backup)
    ask backup "Paperless broke yesterday evening around 20:00. Restore it from the last backup before that."
    yesterday=$(date -d yesterday +%F); good_id=$(printf 'snap%028d' 1)
    called 'nas-restore (list|files)|kopia.*snapshot list' && ok "backup: listed snapshots" || fail "backup: did not list snapshots"
    called 'vm stop 120' && ok "backup: stopped vm-120 first" || fail "backup: did not stop vm-120"
    called 'nas-restore service paperless [^ ]+ --yes' && ok "backup: restored paperless" || fail "backup: did not run nas-restore service paperless"
    if called 'vm stop 120' && called 'nas-restore service paperless'; then
      [ "$(line_of 'vm stop 120')" -lt "$(line_of 'nas-restore service paperless')" ] && ok "backup: stop before restore" || fail "backup: restored while vm-120 running"
    fi
    called 'vm start 120' && ok "backup: started vm-120 again" || fail "backup: did not start vm-120 again"
    called "nas-restore service paperless ($good_id|$yesterday)( |\$)" \
      && ok "backup: restored yesterday's 02:00 snapshot by id/date" || fail "backup: wrong or age-based snapshot selection"
    ;;
  media)
    ask media "Hermes download new bleach ep"
    SK=$(cat "$W/tokens/sonarr-key.token")
    series=$(curl -sf -H "X-Api-Key: $SK" http://127.0.0.1:28989/api/v3/series)
    echo "$series" | jq -e 'any(.[]; .title | test("bleach"; "i"))' >/dev/null && ok "media: Bleach added to Sonarr" || fail "media: Bleach not in Sonarr"
    echo "    series: $(echo "$series" | jq -c '[.[] | {title, seriesType, rootFolderPath, monitored}]')"
    echo "$series" | jq -e 'any(.[]; (.title | test("bleach"; "i")) and .seriesType == "anime")' >/dev/null \
      && ok "media: added as anime" || fail "media: not added as anime"
    cmds=$(curl -sf -H "X-Api-Key: $SK" http://127.0.0.1:28989/api/v3/command)
    echo "    commands: $(echo "$cmds" | jq -c '[.[] | {name, body: (.body.episodeIds // .body.seriesId)}]')"
    echo "$cmds" | jq -e 'any(.[]; .name == "EpisodeSearch" or .name == "SeriesSearch" or .name == "MissingEpisodeSearch")' >/dev/null \
      && ok "media: search triggered" || fail "media: no search triggered"
    ;;
  bill)
    printf '.ps 14\nStadtwerke Duesseldorf AG\n.sp\nRechnung Nr. SW-2026-0815\n.br\nRechnungsdatum: 01.09.2026\n.br\nFaellig am: 15.09.2026\n.sp\nStrom August 2026 ........ 84,20 EUR\n.sp\nGesamtbetrag: 84,20 EUR\n' \
      | groff -Tpdf > "$W/workspace/rechnung-stadtwerke.pdf"
    ask bill "Here is a bill I got (attached: /work/workspace/rechnung-stadtwerke.pdf). File it in paperless and log it in firefly."
    called 'vm start 123' && ok "bill: started Firefly VM" || fail "bill: did not start Firefly VM"
    grep -q '"path": "/paperless/api/documents/post_document/' "$W/log/mock.jsonl" && ok "bill: uploaded to Paperless" || fail "bill: no Paperless upload"
    grep -q 'Token fake-paperless-token' "$W/log/mock.jsonl" && ok "bill: Paperless token used" || fail "bill: Paperless token missing"
    tx=$(grep '"path": "/firefly/api/v1/transactions' "$W/log/mock.jsonl" | grep '"POST"' | tail -1 || true)
    [ -n "$tx" ] && ok "bill: Firefly transaction created" || fail "bill: no Firefly transaction"
    if [ -n "$tx" ]; then
      body=$(echo "$tx" | jq -r .body)
      echo "    transaction: $body"
      echo "$body" | jq -e '.transactions[0].amount | tostring | test("^84[.,]2")' >/dev/null && ok "bill: amount 84.20" || fail "bill: wrong amount"
      echo "$body" | jq -e '.transactions[0].date | tostring | startswith("2026-09")' >/dev/null && ok "bill: date September 2026" || fail "bill: wrong date"
      echo "$body" | jq -e '.transactions[0].type == "withdrawal"' >/dev/null && ok "bill: withdrawal" || fail "bill: not a withdrawal"
      echo "$tx" | jq -e '.auth | test("Bearer fake-firefly-token")' >/dev/null && ok "bill: Firefly token used" || fail "bill: Firefly token missing"
    fi
    ;;
  repo)
    ask repo "Make Firefly's on-demand cooldown 1 hour in the homelab repo and open a PR for it."
    branch=$(git -C "$W/remote.git" for-each-ref --format='%(refname:short)' 'refs/heads/hermes/*' | head -1)
    [ -n "$branch" ] && ok "repo: pushed $branch" || fail "repo: no hermes/* branch pushed"
    [ "$(git -C "$W/remote.git" rev-parse master)" = "$MASTER" ] && ok "repo: master untouched" || fail "repo: master changed"
    called 'lab-pr hermes/' && ok "repo: lab-pr opened the pull request" || fail "repo: lab-pr not used"
    if [ -n "$branch" ]; then
      git -C "$W/remote.git" diff "master...$branch" | sed -n '1,30p' | sed 's/^/      /'
      [ "$(git -C "$W/remote.git" diff --name-only "master...$branch")" = src/instances.tf ] \
        && ok "repo: only src/instances.tf changed" || fail "repo: unexpected files changed"
      git -C "$W/remote.git" show "$branch:src/instances.tf" | grep -A4 '"123" = {' | grep -q 'cooldown = "1h"' \
        && ok "repo: vm-123 cooldown is 1h" || fail "repo: vm-123 cooldown not 1h"
      git -C "$W/remote.git" log --format=%s "master..$branch" | grep -qE '^[a-z]+(\([a-z0-9-]+\))?!?: ' \
        && ok "repo: conventional commit" || fail "repo: commit message not conventional"
    fi
    ;;
  telegram)
    # live: the real bot, polling Telegram, answering only TELEGRAM_ALLOWED_USERS.
    # needs TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS in the environment, e.g.
    #   TELEGRAM_BOT_TOKEN=$(sops -d --extract '["telegram-bot-token"]' src/secrets.json)
    : "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}" "${TELEGRAM_ALLOWED_USERS:?set TELEGRAM_ALLOWED_USERS}"
    WINDOW=${TELEGRAM_WINDOW:-300}
    : > "$W/log/calls.log"
    printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_ALLOWED_USERS=%s\nTELEGRAM_HOME_CHANNEL=%s\nGATEWAY_ALLOW_ALL_USERS=false\n' \
      "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_ALLOWED_USERS" "$TELEGRAM_ALLOWED_USERS" >> "$W/home/.env"
    chmod 600 "$W/home/.env"
    docker rm -f ht-gateway >/dev/null 2>&1 || true
    docker run -d --name ht-gateway --user "$(id -u):$(id -g)" --network "$NET" -v /nix/store:/nix/store:ro -v "$W:/work" \
      -v "$ENV/bin/bash:/bin/bash:ro" -w /work/workspace \
      -e HOME=/work/home -e HERMES_HOME=/work/home -e HERMES_GUEST_ONBOARDING=1 \
      -e SSL_CERT_FILE="$ENV/etc/ssl/certs/ca-bundle.crt" -e PATH="/work/shims:$ENV/bin" \
      alpine hermes gateway >/dev/null
    curl -s -m 20 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TELEGRAM_ALLOWED_USERS" \
      --data-urlencode "text=Homelab test: Hermes (free Nous model, simulated lab) is listening for ${WINDOW}s. Try: start minecraft with the Fabulously Optimized modpack" >/dev/null
    echo ">>> [telegram] gateway running for ${WINDOW}s: message @ApokHomelabBot now"
    sleep "$WINDOW"
    docker logs ht-gateway > "$W/log/gateway.log" 2>&1 || true
    docker rm -f ht-gateway >/dev/null 2>&1 || true
    save_identity
    echo "    lab calls:"; cut -f2- "$W/log/calls.log" | sed 's/^/      /' | head -40
    grep -rhE "telegram|Telegram" "$W"/home/logs/*.log 2>/dev/null | grep -iE "connected|polling|started|unauthori|ignor|message from" | tail -12 | sed 's/^/    log: /'
    grep -rqiE "telegram.*(connected|polling|started)" "$W"/home/logs/*.log "$W/log/gateway.log" 2>/dev/null \
      && ok "telegram: gateway connected" || fail "telegram: gateway did not connect"
    [ -s "$W/log/calls.log" ] && ok "telegram: owner's message drove lab actions" || fail "telegram: no lab actions (no message sent in the window?)"
    ;;
  esac
done

echo
if [ "$FAILED" = 0 ]; then echo ">>> ALL CHECKS PASSED"; else echo ">>> SOME CHECKS FAILED (transcripts: KEEP=1)"; exit 1; fi
