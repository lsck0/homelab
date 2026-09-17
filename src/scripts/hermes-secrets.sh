#!/bin/bash
# Fill the secrets Hermes (vm-113) needs, then run ./sync.sh.
#
#   hermes-ssh-key       generated here, public key goes to src/modules/hermes.pub
#                        (root on every VM and the Proxmox host)
#   hermes-github-key    generated here, registered as a write deploy key on the
#                        GitHub repo so Hermes can push hermes/* branches; the
#                        hermes-pr workflow opens a pull request for each
#   hermes-llm-api-key   Anthropic API key (prompted)
#   telegram-bot-token   from @BotFather (prompted if empty)
#   telegram-chat-id     your numeric Telegram user id (prompted if empty;
#                        message @userinfobot to get it)
#
# The GitHub side needs `gh` logged in as the repo owner. It is idempotent:
# deploy key, a ruleset that lets only repo admins update master (Hermes
# cannot bypass it), and permission for Actions to open pull requests.
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

for tool in sops jq ssh-keygen gh; do
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
# GITHUB (PULL REQUESTS)
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$(current hermes-github-key)" ] || [ "$FORCE" = --force ]; then
  ssh-keygen -q -t ed25519 -N "" -C "hermes@vm-113 github" -f "$tmp/github"
  put hermes-github-key "$(cat "$tmp/github")"
  echo ">>> hermes-github-key generated"
fi
{ current hermes-github-key; echo; } > "$tmp/github"; chmod 600 "$tmp/github"
github_pub=$(ssh-keygen -y -f "$tmp/github" | cut -d' ' -f1-2)

# the deploy key, replacing an older Hermes key
keys=$(gh api "repos/$REPO/keys")
if jq -e --arg k "$github_pub" 'any(.[]; .key == $k)' <<< "$keys" >/dev/null; then
  echo ">>> deploy key already registered"
else
  for id in $(jq -r '.[] | select(.title == "hermes") | .id' <<< "$keys"); do
    gh api -X DELETE "repos/$REPO/keys/$id" >/dev/null
  done
  gh api "repos/$REPO/keys" -f title=hermes -f key="$github_pub" -F read_only=false >/dev/null
  echo ">>> deploy key registered (write)"
fi

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

gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null
echo ">>> Actions may open pull requests"

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
