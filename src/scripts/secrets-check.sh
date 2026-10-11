#!/usr/bin/env bash
# refuse a git index that would publish a secret: run by the pre-commit hook and by sync.sh before it builds and
# before it commits. The repo is public, so a staged secret is one `git push` from being published.
#
# Every staged blob (added, copied, modified, renamed) is checked:
#   - a sops-managed path (a .sops.yaml rule, or one of SOPS_PATHS whatever .sops.yaml says) must hold a sops file
#     whose every value is encrypted: a plaintext key added next to the ciphertext is refused too
#   - a decrypted copy by name (x.dec.json, x.plain.yaml, x.decrypted) is refused wherever it lies
#   - no blob may contain private key material (age, PEM, YubiKey identities)
#   - no blob may contain a secret value: every line of every value of SECRET_VALUE_MIN_CHARS or more, in every file
#     modules/secrets.nix declares a secret in (the terraform vars too), except the `public` kind. This needs the admin
#     key and the flake; without either the scan is skipped with a warning, or refused with --require-values (sync.sh,
#     which always holds the key).
# Limit: a secret that is in no sops file (a token pasted from a website) is caught only by its shape, if it is key
# material; gitleaks or a review must find the rest.
#
# usage: secrets-check.sh [--require-values]
# env: SECRETS_DECLARED  a json file of modules/secrets.nix `declared`, in place of evaluating the flake (tests)
set -euo pipefail

usage() { echo "usage: secrets-check.sh [--require-values]" >&2; exit 2; }
REQUIRE_VALUES=0
for a in "$@"; do
  case "$a" in
    --require-values) REQUIRE_VALUES=1 ;;
    *) usage ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
SRC=src
# shellcheck source=src/scripts/lib/tools.sh
. src/scripts/lib/tools.sh
# shellcheck source=src/scripts/lib/secrets.sh
. src/scripts/lib/secrets.sh
tools_require git jq sops grep

# key material that must never be committed in any file, encrypted sops files aside
# each written so it cannot match its own text, or this file would refuse itself
SECRET_PATTERNS='AGE-SECRET-KEY-1[0-9A-Z]{50,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOC[K]-----|AGE-PLUGIN-YUBIKEY-1[0-9A-Z]{20,}'
# sops-managed whatever .sops.yaml says: a file of a host the rules do not list yet is still one
SOPS_PATHS=('\.sops(\.json)?$')
# names of decrypted copies: sops -d > x.dec.json, x.plain.yaml, x.decrypted
DECRYPTED_NAME='\.(dec|plain|decrypted)(\.|$)'
# shorter values (ports, flags, short ids) collide with ordinary text; every generated secret is 32 hex chars or more
SECRET_VALUE_MIN_CHARS=8
# lines of a multi-line value that are no secret: PEM and PGP armor
ARMOR_LINE='^-----'

# every .sops.yaml path_regex: files under one must be sops-encrypted
mapfile -t SOPS_REGEXES < <(sed -nE 's/^[[:space:]]*-?[[:space:]]*path_regex:[[:space:]]*//p' .sops.yaml 2>/dev/null)
[ "${#SOPS_REGEXES[@]}" -gt 0 ] || { echo "ERROR: no path_regex in .sops.yaml: refusing, the rules decide what must be encrypted" >&2; exit 1; }
SOPS_REGEXES+=("${SOPS_PATHS[@]}")

WORK=$(umask 077; mktemp -d)
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT

# -----------------------------------------------------------------------------
# the values to look for, "<key>\t<line>" in $WORK/values; empty when the key cannot open every values file
# -----------------------------------------------------------------------------
: > "$WORK/values"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/secrets/age.txt}"
# skip_values <why>: the scan cannot run; sync.sh's mode refuses then
skip_values() {
  [ "$REQUIRE_VALUES" = 0 ] || { echo "ERROR: $1; the value scan is required here." >&2; exit 1; }
  echo "WARNING: $1: staged files are not scanned for secret values." >&2
}
if [ -n "${SECRETS_DECLARED:-}" ]; then
  cp "$SECRETS_DECLARED" "$WORK/declared.json"
elif ! nix eval --json --extra-experimental-features "nix-command flakes" "$ROOT_DIR/src#$SECRETS_ATTR.declared" > "$WORK/declared.json" 2>/dev/null; then
  : > "$WORK/declared.json"
fi
if [ ! -s "$WORK/declared.json" ]; then
  skip_values "the flake does not evaluate, so the secret files are unknown"
elif ! grep -qs '^AGE-SECRET-KEY-' "$SOPS_AGE_KEY_FILE"; then
  skip_values "no admin key at $SOPS_AGE_KEY_FILE"
else
  echo '{}' > "$WORK/secrets.json"
  while IFS= read -r f; do
    [ -f "$SRC/$f" ] || continue
    if ! sops --decrypt "$SRC/$f" > "$WORK/one.json" 2>/dev/null; then
      skip_values "src/$f does not decrypt with $SOPS_AGE_KEY_FILE"
      : > "$WORK/secrets.json"
      break
    fi
    jq -s '.[0] + (.[1] | del(.sops))' "$WORK/secrets.json" "$WORK/one.json" > "$WORK/t" && mv "$WORK/t" "$WORK/secrets.json"
  done < <(jq -r '[.[].file] | unique[]' "$WORK/declared.json")
fi
if [ -s "$WORK/secrets.json" ]; then
  jq -r --slurpfile d "$WORK/declared.json" --argjson min "$SECRET_VALUE_MIN_CHARS" --arg armor "$ARMOR_LINE" '
    to_entries[] | select($d[0][.key].kind != "public")
    | .key as $k | (.value | tostring | split("\n")) as $lines
    | range(0; $lines | length) as $i
    # the line after BEGIN is the key format header (openssh-key-v1, cipher, kdf), the same in every key of a type
    | select($i == 0 or ($lines[$i - 1] | test("^-----BEGIN") | not))
    | $lines[$i] | sub("^\\s+"; "") | sub("\\s+$"; "")
    | select(length >= $min and (test($armor) | not)) | "\($k)\t\(.)"' "$WORK/secrets.json" > "$WORK/values"
  cut -f2- "$WORK/values" > "$WORK/patterns"
fi

# sops_file_is_encrypted <blob file>: sops metadata present and every value (keys aside) is ciphertext; sops leaves an
# empty value (a placeholder to fill) as "", which holds nothing
sops_file_is_encrypted() {
  [ "$(sops filestatus --input-type json "$1" 2>/dev/null | jq -r '.encrypted // false' 2>/dev/null)" = true ] || return 1
  jq -e 'del(.sops) | [paths(scalars) as $p | getpath($p)] | all(type == "string" and (. == "" or startswith("ENC[AES256_GCM,")))' \
    "$1" >/dev/null 2>&1
}

problems=0
refuse() { echo "ERROR: $1" >&2; problems=$((problems + 1)); }
while IFS= read -r -d '' path; do
  # a staged deletion has no blob to check
  git cat-file -e ":$path" 2>/dev/null || continue
  git show ":$path" > "$WORK/blob"
  sops_managed=0
  for re in "${SOPS_REGEXES[@]}"; do
    if [[ "$path" =~ $re ]]; then sops_managed=1; break; fi
  done
  if [ "$sops_managed" = 1 ]; then
    sops_file_is_encrypted "$WORK/blob" && continue
    refuse "$path is staged unencrypted, or with a plaintext value beside its ciphertext; encrypt it with src/scripts/sops-encrypt.sh"
    continue
  fi
  if [[ "$path" =~ $DECRYPTED_NAME ]]; then refuse "$path is named like a decrypted copy of a sops file"; fi
  if grep -aqE "$SECRET_PATTERNS" "$WORK/blob"; then refuse "$path contains private key material"; fi
  if [ -s "$WORK/values" ] && grep -aqF -f "$WORK/patterns" "$WORK/blob"; then
    hits=$(while IFS=$'\t' read -r key line; do
      if grep -aqF -- "$line" "$WORK/blob"; then echo "$key"; fi
    done < "$WORK/values" | sort -u | paste -sd' ')
    refuse "$path contains the value of $hits"
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACMR)

[ "$problems" = 0 ] || { echo "ERROR: $problems problem(s) in staged files would publish secrets; nothing committed." >&2; exit 1; }
