#!/usr/bin/env bash
# Reconcile src/secrets.json with the keys the NixOS configs actually read.
#
#   generated   created here with a random value when missing, never touched again
#   manual      created empty when missing; fill with `sops src/secrets.json`
#   anything else in the file is unused and is removed
#
# Idempotent: existing values are preserved. Run after adding or dropping a
# `sops.secrets.<name>` in src/instances/ or src/modules/.
#
#   src/scripts/secrets-sync.sh            show what would change
#   src/scripts/secrets-sync.sh --apply    write and re-encrypt
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT_DIR/src/secrets.json"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

# the age key lives in the dotfiles repo; secrets/age.txt here is a symlink to it.
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/secrets/age.txt}"

# secrets whose value only has to be consistent inside the lab.
GENERATED=(
  lldap-admin-password lldap-jwt-secret authelia-admin-pass
  forgejo-admin-pass forgejo-oidc-secret
  vaultwarden-oidc-secret nextcloud-oidc-secret nextcloud-admin-pass
  audiobookshelf-oidc-secret kavita-oidc-secret
  restic-password minecraft-rcon-password
  firefly-db-password
  crowdsec-bouncer-key
  ntfy-admin-password ntfy-grafana-password ntfy-hermes-password
  wazuh-admin-password
  # unguessable URL path segments: the read feed and the push endpoint.
  calendar-token calendar-upload-token
)

# secrets that come from outside and cannot be invented.
MANUAL=(
  cloudflare-token proxmox-api-token proxmox-user proxmox-pass
  attic-server-token attic-pull-token
  calendar-sources kraken-api-key kraken-api-secret
  telegram-bot-token telegram-chat-id
  hermes-ssh-key hermes-llm-api-key hermes-github-app-key
  hermes-gemini-api-key hermes-glm-api-key
  github-runner-token
  wireguard-private-key firefly-app-key
)

command -v sops >/dev/null || { echo "ERROR: sops not installed."; exit 1; }
[ -f "$SECRETS" ] || { echo "ERROR: $SECRETS missing. Run src/scripts/init.sh first."; exit 1; }
[ -r "$SOPS_AGE_KEY_FILE" ] || { echo "ERROR: age key not readable at $SOPS_AGE_KEY_FILE"; exit 1; }

PLAIN=$(mktemp); OUT=$(mktemp)
trap 'shred -u "$PLAIN" "$OUT" 2>/dev/null || rm -f "$PLAIN" "$OUT"' EXIT
chmod 600 "$PLAIN" "$OUT"

sops --decrypt "$SECRETS" > "$PLAIN"

wanted=$(printf '%s\n' "${GENERATED[@]}" "${MANUAL[@]}" | sort)
have=$(jq -r 'keys[] | select(. != "sops")' "$PLAIN" | sort)

added=(); removed=()
while read -r k; do [ -n "$k" ] && added+=("$k"); done < <(comm -23 <(echo "$wanted") <(echo "$have"))
while read -r k; do [ -n "$k" ] && removed+=("$k"); done < <(comm -13 <(echo "$wanted") <(echo "$have"))

cp "$PLAIN" "$OUT"
for k in "${removed[@]}"; do
  jq --arg k "$k" 'del(.[$k])' "$OUT" > "$OUT.t" && mv "$OUT.t" "$OUT"
  echo "remove  $k (no config reads it)"
done
for k in "${added[@]}"; do
  if printf '%s\n' "${GENERATED[@]}" | grep -qx "$k"; then
    v=$(openssl rand -hex 24); echo "add     $k (generated)"
  else
    v=""; echo "add     $k (empty, fill with: sops src/secrets.json)"
  fi
  jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$OUT" > "$OUT.t" && mv "$OUT.t" "$OUT"
done

if [ "${#added[@]}" -eq 0 ] && [ "${#removed[@]}" -eq 0 ]; then
  echo "secrets.json already matches the configs."
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "dry run. Re-run with --apply to write and re-encrypt."
  exit 0
fi

# keep the sops metadata out of the plaintext we re-encrypt.
jq 'del(.sops)' "$OUT" > "$OUT.t" && mv "$OUT.t" "$OUT"
cp "$OUT" "$SECRETS"
sops --encrypt --in-place "$SECRETS"
sops --decrypt "$SECRETS" > /dev/null || { echo "ERROR: re-encrypted file does not decrypt."; exit 1; }
echo "src/secrets.json updated and re-encrypted."
