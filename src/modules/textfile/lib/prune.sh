#!/usr/bin/env bash
# textfile-prune <dir> <pattern>...: removes the .prom files of names the previous run recorded in <dir>/.declared
# and none of the patterns covers any more, then records the patterns; a file never recorded is left alone
set -u

dir=$1
shift
record=$dir/.declared

declared() {
  local name=$1 pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2254 # a declared name is a shell pattern
    case "$name" in $pattern) return 0 ;; esac
  done
  return 1
}

if [ -f "$record" ]; then
  while IFS= read -r previous; do
    [ -n "$previous" ] || continue
    # shellcheck disable=SC2231 # the recorded name is a glob
    for file in "$dir"/$previous.prom "$dir"/$previous.prom.tmp; do
      [ -e "$file" ] || continue
      name=${file##*/}
      name=${name%.tmp}
      name=${name%.prom}
      declared "$name" "$@" && continue
      rm -f "$file"
      echo "textfile: removed $file, no unit of this host writes it any more"
    done
  done < "$record"
fi

mkdir -p "$dir"
printf '%s\n' "$@" > "$record.tmp"
mv "$record.tmp" "$record"
