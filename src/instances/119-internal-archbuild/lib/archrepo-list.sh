#!/usr/bin/env bash
# print every package name the lsck0 snapshot serves, read from an arch-dotfiles checkout
#
# usage: archrepo-list.sh <dotfiles dir> [<sync db>]
#
# The snapshot serves every machine, so the list is the union over all of them: the packages.txt of every module
# (arch-dotfiles scripts/lib/platform.sh platform_groups_all: a module is a configs/<module>/ with one) plus the
# EXTRA_PACKAGES of every platforms/*.sh. A manifest is read like install.sh read_manifest does: one name per line,
# `#` comments, trailing whitespace and blank lines dropped. flatpacks.txt and nixpkgs.txt are not pacman packages.
# Prints the names sorted and unique, one per line.
#
# With a sync db (repo-add's <repo>.db.tar.gz) it prints only the listed names the db does not provide: neither a
# package name, a provides nor a group, the three ways install.sh's pacman -S resolves a target. archrepo-build.sh's
# completeness gate runs it on the proposed and on the served db.
#
# An unreadable manifest, a platform file that does not source, an entry that is not a package name, an empty list
# and an unreadable db fail the whole run: archrepo-build.sh prunes what the list misses from the served db.
set -euo pipefail
shopt -s nullglob

# -----------------------------------------------------------------------------
# CONSTANTS
DOTFILES=${1:?arch-dotfiles checkout}
DB=${2:-}
MODULES=configs
MANIFEST=packages.txt
PLATFORMS=platforms
# makepkg's pkgname rule: alphanumerics and @._+-, not starting with a hyphen or a dot
NAME_PATTERN='^[a-z0-9@_+][a-z0-9@._+-]*$'

# -----------------------------------------------------------------------------
# FUNCTIONS
die() {
  echo "archrepo-list: $*" >&2
  exit 1
}

manifest_read() { sed -E 's/#.*//; s/[[:space:]]+$//' "$1" | awk 'NF'; }

# sourced like install.sh does, in a clean shell of its own; an unset EXTRA_PACKAGES prints one empty line
platform_extra_packages() {
  # shellcheck disable=SC2016 # expanded by the inner shell
  env -i "$BASH" -c 'source "$1" >/dev/null && printf "%s\n" "${EXTRA_PACKAGES[@]}"' platform "$1"
}

names_add() {
  local source=$1 entries=$2 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [[ $name =~ $NAME_PATTERN ]] || die "$source: '$name' is not a package name"
    names+=("$name")
  done <<<"$entries"
}

# every name, provides (version dropped) and group of the db's desc entries, one per line
db_provided() {
  bsdtar -xOf "$1" | awk '/^%[A-Z0-9]+%$/ { section = $0; next } /^$/ { section = ""; next }
    section == "%NAME%" || section == "%PROVIDES%" || section == "%GROUPS%" { sub(/[<>=].*/, ""); print }'
}

# -----------------------------------------------------------------------------
# MAIN
names=()
manifests=("$DOTFILES/$MODULES"/*/"$MANIFEST")
(( ${#manifests[@]} > 0 )) || die "no $MODULES/<module>/$MANIFEST in $DOTFILES"
for file in "${manifests[@]}"; do
  entries=$(manifest_read "$file") || die "cannot read $file"
  names_add "$file" "$entries"
done
for file in "$DOTFILES/$PLATFORMS"/*.sh; do
  entries=$(platform_extra_packages "$file") || die "cannot source $file for its EXTRA_PACKAGES"
  names_add "$file" "$entries"
done
(( ${#names[@]} > 0 )) || die "no package names in $DOTFILES"
listed=$(printf '%s\n' "${names[@]}" | LC_ALL=C sort -u)
if [ -z "$DB" ]; then
  echo "$listed"
  exit 0
fi
provided=$(db_provided "$DB") || die "cannot read $DB"
LC_ALL=C comm -23 <(echo "$listed") <(echo "$provided" | LC_ALL=C sort -u)
