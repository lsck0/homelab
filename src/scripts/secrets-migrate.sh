#!/usr/bin/env bash
# one-time move to per-folder secrets: src/secrets.json (every value) and src/host-keys.json (every host's age key by
# hostname) become src/secrets/shared.sops.json and each host's <home>/age.sops and age.pub, then secrets-sync.sh --apply
# moves every value the layout (modules/secrets.nix) places in a folder there and writes the shared copies and the
# rules. src/host-secrets/ was derived from the old files and goes with them. Host keys carry over, so deployed
# guests keep decrypting; a host without an old key gets a new one, the key of a host that is gone is dropped.
#
# On the new layout it does nothing. It refuses a tree holding parts of both layouts, or half of the old one, naming
# the files: one of them is incomplete and this script cannot tell which. Nothing is written before every check
# passed, and the old files go only once every new one is in place.
#
# usage: secrets-migrate.sh [--plan <file>]
# env: SOPS_AGE_KEY_FILE, SECRETS_ADMIN_RECIPIENTS: as for secrets-sync.sh
set -euo pipefail

usage() { echo "usage: secrets-migrate.sh [--plan <file>]" >&2; exit 2; }
PLAN_IN=""
case "${1:-}" in
  "") ;;
  --plan) [ $# = 2 ] || usage; PLAN_IN=$2 ;;
  *) usage ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/src"
OLD_VALUES="$SRC/secrets.json"
OLD_KEYS="$SRC/host-keys.json"
OLD_HOST_FILES="$SRC/host-secrets"
ENCRYPT="$SRC/scripts/sops-encrypt.sh"

# shellcheck source=src/scripts/lib/tools.sh
. "$SRC/scripts/lib/tools.sh"
# shellcheck source=src/scripts/lib/secrets.sh
. "$SRC/scripts/lib/secrets.sh"
NEW_VALUES="$SRC/$SECRETS_CATALOG_FILE"
tools_require sops jq age-keygen
[ -n "$PLAN_IN" ] || tools_require nix
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/secrets/age.txt}"

# -----------------------------------------------------------------------------
# CHECKS: the whole old layout and nothing of the new one
# -----------------------------------------------------------------------------
mapfile -t new_files < <(
  [ ! -e "$NEW_VALUES" ] || echo "src/$SECRETS_CATALOG_FILE"
  for dir in "${SECRETS_HOME_DIRS[@]}"; do
    for path in "$SRC/$dir"/*/{"$SECRETS_KEY_NAME","$SECRETS_PUB_NAME","$SECRETS_VALUES_NAME","$SECRETS_SHARED_NAME"}; do
      [ ! -e "$path" ] || echo "${path#"$ROOT_DIR/"}"
    done
  done)
if [ ! -e "$OLD_VALUES" ] && [ ! -e "$OLD_KEYS" ] && [ -e "$NEW_VALUES" ]; then
  echo "secrets-migrate: the secrets are per folder already, nothing to do."
  exit 0
fi
if [ ! -e "$OLD_VALUES" ] || [ ! -e "$OLD_KEYS" ] || [ "${#new_files[@]}" -gt 0 ]; then
  echo "ERROR: the tree holds a partial secrets layout, refusing to guess which half is complete:" >&2
  for f in "$OLD_VALUES" "$OLD_KEYS"; do
    if [ -e "$f" ]; then echo "  old, present: ${f#"$ROOT_DIR/"}" >&2; else echo "  old, missing: ${f#"$ROOT_DIR/"}" >&2; fi
  done
  for f in "${new_files[@]}"; do echo "  new, present: $f" >&2; done
  echo "       Restore the complete old layout from git and remove the new files, then run this again." >&2
  exit 1
fi

secrets_admins_load
WORK=$(umask 077; mktemp -d)
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT
secrets_plan_load "$WORK/plan.json" "$PLAN_IN"
sops --decrypt "$OLD_VALUES" | jq 'del(.sops)' > "$WORK/values.json" \
  || { echo "ERROR: src/secrets.json does not decrypt with $SOPS_AGE_KEY_FILE" >&2; exit 1; }
sops --decrypt "$OLD_KEYS" | jq 'del(.sops)' > "$WORK/keys.json" \
  || { echo "ERROR: src/host-keys.json does not decrypt with $SOPS_AGE_KEY_FILE" >&2; exit 1; }

# -----------------------------------------------------------------------------
# MOVE: keys into their homes, every value into src/secrets/shared.sops.json, then the old files go
# -----------------------------------------------------------------------------
admins=$(IFS=,; echo "${ADMIN_RECIPIENTS[*]}")
while IFS=$'\t' read -r config home key; do
  mkdir -p "$SRC/$home"
  printf '%s\n' "$key" | "$ENCRYPT" --age "$admins" "$SRC/$home/$SECRETS_KEY_NAME"
  age-keygen -y <<<"$key" > "$SRC/$home/$SECRETS_PUB_NAME"
  echo "key     $config: carried over"
done < <(jq -r --slurpfile keys "$WORK/keys.json" \
  '.hosts | to_entries[] | select($keys[0][.value.hostName]) | [.key, .value.home, $keys[0][.value.hostName]] | @tsv' "$WORK/plan.json")
jq -r --slurpfile plan "$WORK/plan.json" '([$plan[0].hosts[].hostName]) as $live | keys[] | select(. as $h | $live | index($h) | not)
  | "drop    the key of \(.) (no such host)"' "$WORK/keys.json"
mkdir -p "$(dirname "$NEW_VALUES")"
"$ENCRYPT" --age "$admins" "$NEW_VALUES" < "$WORK/values.json"
rm -f "$OLD_VALUES" "$OLD_KEYS"
rm -rf "$OLD_HOST_FILES"
echo ">>> Secrets: the old layout is moved; secrets-sync.sh places every value now."

"$SRC/scripts/secrets-sync.sh" --apply ${PLAN_IN:+--plan "$PLAN_IN"} || {
  echo "ERROR: the move is done, placing the values is not: fix the error above, then src/scripts/secrets-sync.sh --apply" >&2
  exit 1
}
