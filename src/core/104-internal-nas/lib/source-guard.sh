#!/usr/bin/env bash
# source_guard <dir> <marker>: fails, saying why, for a folder that is missing, lacks its marker (an unmounted or
# wiped folder) or holds nothing beside it; such a folder must never read as one whose every file was deleted
#
# Prepended to proton-mirror.sh and proton-bisync.sh by their derivations (proton-mirror.nix, proton-bisync.nix).
source_guard() {
  if [ ! -e "$1/$2" ]; then
    echo "no $2 in $1: missing, unmounted or wiped; refusing to sync" >&2
    return 1
  fi
  if [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name "$(basename "$2")" -print -quit)" ]; then
    echo "$1 holds nothing beside $2; refusing to sync" >&2
    return 1
  fi
}
