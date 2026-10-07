#!/usr/bin/env bash
# fetch arch-dotfiles at <ref> into <dir> and print the commit, only when it is signed by the pinned key
#
# usage: archrepo-fetch.sh <source> <ref> <dir> <primary key fingerprint>
#
# Runs on the vm-119 host before any container (archbuild.service): the build trusts the module manifests,
# the platform files it sources, mirror/pkgbuilds and mirror/overrides.conf of this commit, and everything
# built from them gets the repo key's signature. The rule is arch-dotfiles' bootstrap.sh clone_verify: `git verify-commit` passes
# AND the primary key of the signature is the pinned one. The key file is read from the unverified
# commit, which is harmless: a commit signed by any other key it ships fails the fingerprint check.
# Not covered, as in bootstrap.sh: a replay of an older signed commit of <ref>.
#
# <dir> is the host's alone: the containers get it read-only, so nothing a build runs can plant git
# config or hooks that this script would execute as root on the next run.
set -euo pipefail

# -----------------------------------------------------------------------------
# CONSTANTS
SOURCE=${1:?git url of arch-dotfiles}
REF=${2:?branch to build}
DIR=${3:?checkout directory}
FINGERPRINT=${4:?primary key fingerprint the commit must be signed by}
# arch-dotfiles bootstrap.sh SIGNING_KEY_FILE
KEY_FILE=configs/base/gnupg/luca-sandrock.pub.asc
FETCH_TIMEOUT=15m
# a v4 fingerprint as gpg prints it
FINGERPRINT_PATTERN='^[0-9A-F]{40}$'

# -----------------------------------------------------------------------------
# MAIN
[[ $FINGERPRINT =~ $FINGERPRINT_PATTERN ]] || { echo "fetch: '$FINGERPRINT' is not a v4 fingerprint" >&2; exit 1; }
[ -d "$DIR/.git" ] || { rm -rf "$DIR"; git init -q "$DIR"; }
timeout "$FETCH_TIMEOUT" git -C "$DIR" fetch -q --depth 1 "$SOURCE" "$REF"
commit=$(git -C "$DIR" rev-parse --verify 'FETCH_HEAD^{commit}')

gnupg_home=$(mktemp -d)
trap 'GNUPGHOME="$gnupg_home" gpgconf --kill all; rm -rf "$gnupg_home"' EXIT
git -C "$DIR" show "$commit:$KEY_FILE" | GNUPGHOME="$gnupg_home" gpg --batch --quiet --import
verified=0
status=$(GNUPGHOME="$gnupg_home" git -C "$DIR" verify-commit --raw "$commit" 2>&1) && verified=1
# gpg status line: VALIDSIG <signing key> ... <primary key>, field 12 counting the [GNUPG:] prefix
signer=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $12 }' <<<"$status")
if (( ! verified )) || [ "$signer" != "$FINGERPRINT" ]; then
  verdict=$(awk '$1 == "[GNUPG:]" && $2 ~ /^(GOOD|BAD|EXP|EXPKEY|REVKEY|ERR)SIG$/ { print $2 }' <<<"$status" | paste -sd' ')
  echo "fetch: $SOURCE $REF $commit is not signed by $FINGERPRINT (gpg: ${verdict:-NOSIG}, primary key: ${signer:-none})," \
    "refusing to build it; the published snapshot stays" >&2
  exit 1
fi

git -C "$DIR" checkout -q --force --detach "$commit"
git -C "$DIR" clean -qfdx
echo "$commit"
