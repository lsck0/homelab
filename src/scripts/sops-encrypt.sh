#!/usr/bin/env bash
# usage: <plaintext json on stdin> | sops-encrypt.sh <target>
# writes <target> encrypted by the .sops.yaml rule its path matches; plaintext never touches the repo
set -euo pipefail

TARGET=${1:?usage: sops-encrypt.sh <target> < plaintext.json}
DIR=$(dirname "$TARGET")
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP=$(umask 077; mktemp "$DIR/.sops-encrypt.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# --filename-override picks the creation rule (recipients) of the target, not of /dev/stdin
(cd "$ROOT_DIR" && sops --encrypt --filename-override "$TARGET" --input-type json --output-type json /dev/stdin) > "$TMP"
[ "$(sops filestatus "$TMP" | jq -r .encrypted)" = true ] || { echo "ERROR: $TARGET: sops wrote an unencrypted file." >&2; exit 1; }
sops --decrypt --input-type json --output-type json "$TMP" > /dev/null \
  || { echo "ERROR: $TARGET: the encrypted file does not decrypt with this key." >&2; exit 1; }
mv "$TMP" "$TARGET"
trap - EXIT
