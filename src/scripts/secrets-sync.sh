#!/usr/bin/env bash
# reconcile src/secrets.json with the keys nix configs read
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS="$ROOT_DIR/src/secrets.json"
APPLY=0
PRUNE=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --prune) PRUNE=1 ;;
  esac
done

# secrets/age.txt symlinks to the dotfiles key
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/secrets/age.txt}"

# lab-internal secrets, only need to be consistent
GENERATED=(
  lldap-admin-password lldap-jwt-secret authelia-admin-pass lldap-guest-password
  forgejo-admin-pass forgejo-oidc-secret headplane-oidc-secret homeassistant-oidc-secret headscale-oidc-secret
  kopia-password minecraft-rcon-password
  firefly-db-password
  crowdsec-bouncer-key
  ntfy-admin-password ntfy-grafana-password ntfy-hermes-password
  ntfy-desktop-token
  # unguessable url segments for feed and push
  calendar-upload-token
  # registry pushes as user ci; set it as REGISTRY_PASSWORD on the repos that push images
  registry-push-password
  # registry pushes as user builder: the app builder on vm-117 only
  registry-builder-password
)

# external secrets that cannot be invented
MANUAL=(
  cloudflare-token proxmox-api-token proxmox-user proxmox-pass
  attic-server-token attic-pull-token
  calendar-sources
  telegram-bot-token telegram-chat-id
  hermes-ssh-key hermes-llm-api-key hermes-github-app-key
  hermes-gemini-api-key hermes-glm-api-key
  github-runner-token
  wireguard-private-key firefly-app-key
  # the proton account itself: proton-drive on the nas signs in with it (proton-drive-login), protonvpn-private-key is the vpn
  proton-username proton-password proton-totp-secret
  # the app builder's ssh key to the swarm manager: ssh-keygen -t ed25519, public half in modules/swarm.nix
  app-deploy-key
)

# ntfy needs tk_ + 29 [a-z0-9], a hex token stops it from starting
NTFY_TOKENS=(ntfy-desktop-token)

# dotfiles configs/ntfy reads its token from here
DOTFILES_SECRETS="${DOTFILES:-$HOME/projects/arch-dotfiles}/configs/secrets"

command -v sops >/dev/null || { echo "ERROR: sops not installed."; exit 1; }
[ -f "$SECRETS" ] || { echo "ERROR: $SECRETS missing. Run src/scripts/init.sh first."; exit 1; }
[ -r "$SOPS_AGE_KEY_FILE" ] || { echo "ERROR: age key not readable at $SOPS_AGE_KEY_FILE"; exit 1; }

PLAIN=$(mktemp); OUT=$(mktemp)
trap 'shred -u "$PLAIN" "$OUT" 2>/dev/null || rm -f "$PLAIN" "$OUT"' EXIT
chmod 600 "$PLAIN" "$OUT"

sops --decrypt "$SECRETS" > "$PLAIN"

# names the configs reference: the real in-use set
# templates are rendered files; example-only names are harmless extras
referenced=$(grep -rhoE 'sops\.(secrets|placeholder)\.[a-zA-Z0-9_-]+' \
    "$ROOT_DIR/src" --include='*.nix' 2>/dev/null \
  | sed -E 's/.*\.//' | sort -u)

# the app catalog's secrets and how to make each: {"<name>": "hex:<bytes>" | "garage-key-id"}
APP_SECRETS=$(nix-instantiate --eval --strict --json -E "
  let c = import $ROOT_DIR/src/modules/apps.nix;
  in builtins.foldl' (acc: name: acc // (c.apps.\${name}.secrets or { })) { } (builtins.attrNames c.apps)")

wanted=$(printf '%s\n' "${GENERATED[@]}" "${MANUAL[@]}" $referenced $(jq -r 'keys[]' <<<"$APP_SECRETS") | sort -u)
have=$(jq -r 'keys[] | select(. != "sops")' "$PLAIN" | sort)

added=(); removed=()
while read -r k; do [ -n "$k" ] && added+=("$k"); done < <(comm -23 <(echo "$wanted") <(echo "$have"))
while read -r k; do [ -n "$k" ] && removed+=("$k"); done < <(comm -13 <(echo "$wanted") <(echo "$have"))

cp "$PLAIN" "$OUT"
if [ "$PRUNE" -eq 1 ]; then
  for k in "${removed[@]}"; do
    jq --arg k "$k" 'del(.[$k])' "$OUT" > "$OUT.t" && mv "$OUT.t" "$OUT"
    echo "remove  $k (no config references it)"
  done
else
  for k in "${removed[@]}"; do
    echo "unused  $k (nothing references it; --prune to delete)"
  done
  removed=()
fi
for k in "${added[@]}"; do
  if printf '%s\n' "${NTFY_TOKENS[@]}" | grep -qx "$k"; then
    # bounded input: tr reading /dev/urandom dies of SIGPIPE when head closes, and pipefail aborts the script
    v="tk_$(head -c 512 /dev/urandom | LC_ALL=C tr -dc a-z0-9 | cut -c1-29)"
    [ "${#v}" -eq 32 ] || { echo "ERROR: could not generate $k"; exit 1; }
    echo "add     $k (generated)"
  elif generator=$(jq -er --arg k "$k" '.[$k] // empty' <<<"$APP_SECRETS"); then
    case "$generator" in
      hex:*) v=$(openssl rand -hex "${generator#hex:}") ;;
      # garage access keys are GK plus 12 random bytes in hex
      garage-key-id) v="GK$(openssl rand -hex 12)" ;;
      *) echo "ERROR: $k: unknown generator $generator in modules/apps.nix"; exit 1 ;;
    esac
    echo "add     $k (generated, $generator)"
  elif printf '%s\n' "${GENERATED[@]}" | grep -qx "$k"; then
    v=$(openssl rand -hex 24); echo "add     $k (generated)"
  else
    v=""; echo "add     $k (empty, fill with: sops src/secrets.json)"
  fi
  jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$OUT" > "$OUT.t" && mv "$OUT.t" "$OUT"
done

# mirror to dotfiles; a locked worktree holds ciphertext, skip it then
mirrored=0
want=$(jq -r '.["ntfy-desktop-token"] // empty' "$OUT")
if [ -n "$want" ] && [ "$(cat "$DOTFILES_SECRETS/ntfy-desktop-token" 2>/dev/null)" != "$want" ]; then
  if ! grep -qs '^AGE-SECRET-KEY-' "$DOTFILES_SECRETS/age.txt"; then
    echo "skip    dotfiles ntfy-desktop-token (dotfiles secrets locked)"
  elif [ "$APPLY" -eq 1 ]; then
    (umask 077; printf '%s\n' "$want" > "$DOTFILES_SECRETS/ntfy-desktop-token")
    echo "mirror  ntfy-desktop-token -> dotfiles secrets (commit it with the dotfiles sync.sh)"
    mirrored=1
  else
    echo "mirror  ntfy-desktop-token -> dotfiles secrets"
    mirrored=1
  fi
fi
unset want

if [ "${#added[@]}" -eq 0 ] && [ "${#removed[@]}" -eq 0 ] && [ "$mirrored" -eq 0 ]; then
  echo "secrets.json already matches the configs."
  exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "dry run. Re-run with --apply to write and re-encrypt (add --prune to delete unused keys)."
  exit 0
fi

# only the dotfiles copy changed
if [ "${#added[@]}" -eq 0 ] && [ "${#removed[@]}" -eq 0 ]; then
  exit 0
fi

# keep sops metadata out of the re-encrypted plaintext; the plaintext never lands in the repo
jq 'del(.sops)' "$OUT" | "$ROOT_DIR/src/scripts/sops-encrypt.sh" "$SECRETS"
echo "src/secrets.json updated and re-encrypted."
