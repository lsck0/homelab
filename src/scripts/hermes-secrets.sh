#!/bin/bash
# Fill the secrets Hermes (vm-113) needs, then run ./sync.sh.
#
#   hermes-ssh-key       generated here, public key goes to src/modules/hermes.pub
#                        (root on every VM and the Proxmox host)
#   hermes-llm-api-key   Anthropic API key (prompted)
#   telegram-bot-token   from @BotFather (prompted if empty)
#   telegram-chat-id     your numeric Telegram user id (prompted if empty;
#                        message @userinfobot to get it)
#
# Existing non-empty values are kept. Pass --force to re-enter them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECRETS="$ROOT_DIR/src/secrets.json"
PUB="$ROOT_DIR/src/modules/hermes.pub"
export SOPS_AGE_KEY_FILE="$ROOT_DIR/secrets/age.txt"
FORCE="${1:-}"

for tool in sops jq ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required."; exit 1; }
done

current() { sops -d --extract "[\"$1\"]" "$SECRETS" 2>/dev/null || true; }
put() { sops set "$SECRETS" "[\"$1\"]" "$(jq -Rs . <<< "$2" | sed 's/\\n"$/"/')"; }

# SSH key
if [ -z "$(current hermes-ssh-key)" ] || [ "$FORCE" = --force ] || [ ! -f "$PUB" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "hermes@vm-113" -f "$tmp/key"
  put hermes-ssh-key "$(cat "$tmp/key")"
  cp "$tmp/key.pub" "$PUB"
  git -C "$ROOT_DIR" add "$PUB"
  echo ">>> hermes-ssh-key generated, public key in src/modules/hermes.pub"
else
  echo ">>> hermes-ssh-key already set"
fi

ask() { # name prompt
  if [ -n "$(current "$1")" ] && [ "$FORCE" != --force ]; then
    echo ">>> $1 already set"; return
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
