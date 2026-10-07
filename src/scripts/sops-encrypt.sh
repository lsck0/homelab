#!/usr/bin/env bash
# usage: <plaintext on stdin> | sops-encrypt.sh [--age <recipient,...>] <target>
# writes <target> encrypted by the .sops.yaml rule its path matches, or to the --age recipients when no rule covers it
# yet (secrets-migrate.sh); plaintext never touches the repo. A *.json target is a json document, any other (age.sops)
# a binary blob.
#
# Every call encrypts afresh, with a new data key: the admin-key rotation (secrets-sync.sh) depends on it. The
# ciphertext lands next to the target and is renamed into place only once it decrypts with this run's key, so a
# failed call leaves the target as it was and no temp file behind.
set -euo pipefail

usage() { echo "usage: sops-encrypt.sh [--age <recipient,...>] <target> < plaintext" >&2; exit 2; }
AGE=()
# an empty config: with a .sops.yaml that has no rule for the target, sops refuses even explicit recipients
if [ "${1:-}" = --age ]; then [ $# -ge 2 ] || usage; AGE=(--config /dev/null --age "$2"); shift 2; fi
[ $# = 1 ] || usage
TARGET=$1
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# the creation rules match repo-relative paths (src/...), whatever directory the caller runs in
TARGET_ABS=$(realpath -m "$TARGET")
TARGET_REL=$(realpath -m --relative-to="$ROOT_DIR" "$TARGET_ABS")
case "$TARGET_REL" in ../*) echo "ERROR: $TARGET is outside the repo $ROOT_DIR." >&2; exit 2 ;; esac
case "$TARGET_REL" in *.json) TYPE=json ;; *) TYPE=binary ;; esac

TMP=$(umask 077; mktemp "$(dirname "$TARGET_ABS")/.sops-encrypt.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# --filename-override picks the creation rule (recipients) of the target, not of /dev/stdin
(cd "$ROOT_DIR" && sops --encrypt "${AGE[@]}" --filename-override "$TARGET_REL" --input-type "$TYPE" --output-type "$TYPE" /dev/stdin) > "$TMP"
[ "$(sops filestatus --input-type "$TYPE" "$TMP" | jq -r .encrypted)" = true ] || { echo "ERROR: $TARGET: sops wrote an unencrypted file." >&2; exit 1; }
sops --decrypt --input-type "$TYPE" --output-type "$TYPE" "$TMP" > /dev/null \
  || { echo "ERROR: $TARGET: the encrypted file does not decrypt with this key." >&2; exit 1; }
mv "$TMP" "$TARGET_ABS"
trap - EXIT
