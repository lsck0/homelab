#!/usr/bin/env bash
# Install Suwayomi's manga sources.
#
# Suwayomi ships with no sources at all - only "Local source" - so a fresh
# instance can search nothing. The extension store is configured
# (EXTENSION_STORES, the keiyoushi repo) but installing from it is a manual
# click per source in the UI, which is exactly the kind of state that
# disappears the next time the container is rebuilt.
#
# Idempotent: the extension list says what is already installed, so this only
# fetches what is missing and is safe on a timer.
set -euo pipefail

SUWAYOMI=${SUWAYOMI:-http://127.0.0.1:4567}
API="$SUWAYOMI/api/v1"

# Package names from the keiyoushi repo. Chosen for coverage rather than
# length: MangaDex and MANGA Plus are the two that carry most of what anyone
# actually looks for, MANGA Plus being Shueisha's own official releases.
# Everything here serves English among other languages.
SOURCES=${SUWAYOMI_SOURCES:-"
eu.kanade.tachiyomi.extension.all.mangadex
eu.kanade.tachiyomi.extension.all.mangaplus
eu.kanade.tachiyomi.extension.en.weebcentral
eu.kanade.tachiyomi.extension.all.comicklive
eu.kanade.tachiyomi.extension.en.dynasty
"}

extensions=$(curl -sf -m 60 "$API/extension/list") \
  || { echo "suwayomi: unreachable"; exit 1; }
count=$(echo "$extensions" | jq 'length')
[ "$count" -gt 0 ] || { echo "suwayomi: the extension store returned nothing"; exit 1; }

installed=0 already=0 problems=0
for pkg in $SOURCES; do
  state=$(echo "$extensions" | jq -r --arg p "$pkg" \
    'first(.[] | select(.pkgName == $p)) | if . == null then "absent" elif .installed then "installed" else "available" end')
  case "$state" in
    installed) already=$((already + 1)); continue ;;
    absent)
      # a repo can drop or rename an extension; say so rather than failing the
      # unit and retrying the same missing name for ever
      echo "suwayomi: $pkg is not in the extension store"
      problems=$((problems + 1))
      continue
      ;;
  esac
  # the install pulls an apk and unpacks it, so it is slow the first time
  if curl -sf -m 300 -o /dev/null "$API/extension/install/$pkg"; then
    echo "suwayomi: installed $pkg"
    installed=$((installed + 1))
  else
    echo "suwayomi: installing $pkg failed"
    problems=$((problems + 1))
  fi
done

sources=$(curl -sf -m 60 "$API/source/list" | jq 'length')
echo "suwayomi: $installed installed, $already already present, $sources sources available"
[ "$problems" -eq 0 ]
