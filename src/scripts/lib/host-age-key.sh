#!/usr/bin/env bash
# on a guest, with its own age key on stdin: host-age-key.sh push|settle <key file>
#   push    a key that differs goes ahead of the identities the file holds, so the running system and the next boot
#           still decrypt until a switch takes the new one; prints "changed" when it did
#   settle  after a switch that decrypted with it, the file holds that key alone
# sync.sh runs it around each deploy's switch.
set -euo pipefail

action=$1
key_file=$2
case "$action" in
  push|settle) ;;
  *) echo "usage: host-age-key.sh push|settle <key file>" >&2; exit 2 ;;
esac
umask 077
install -d -m 700 "$(dirname "$key_file")"
cat > "$key_file.new"
case "$action" in
  push)
    if cmp -s "$key_file.new" "$key_file"; then
      rm "$key_file.new"
      exit 0
    fi
    cp "$key_file.new" "$key_file.both"
    if [ -f "$key_file" ]; then grep -vxF -f "$key_file.new" "$key_file" >> "$key_file.both" || [ "$?" = 1 ]; fi
    mv "$key_file.both" "$key_file"
    rm "$key_file.new"
    echo changed ;;
  settle) mv "$key_file.new" "$key_file" ;;
esac
