#!/usr/bin/env bash
# refuse a git index holding plaintext secrets: run by the pre-commit hook and by sync.sh before its commit
# the repo is public, so a staged plaintext secret is one `git push` from being published
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# key material that must never be committed in any file, encrypted sops files aside
SECRET_PATTERNS='AGE-SECRET-KEY-1[0-9A-Z]{50,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AGE-PLUGIN-YUBIKEY-1[0-9A-Z]{20,}'

# every .sops.yaml path_regex: files under one must be sops-encrypted
mapfile -t SOPS_REGEXES < <(sed -nE 's/^[[:space:]]*-?[[:space:]]*path_regex:[[:space:]]*//p' .sops.yaml)
[ "${#SOPS_REGEXES[@]}" -gt 0 ] || { echo "ERROR: no path_regex in .sops.yaml" >&2; exit 1; }

problems=0
while IFS= read -r -d '' path; do
  # a staged deletion has no blob to check
  git cat-file -e ":$path" 2>/dev/null || continue
  sops_managed=0
  for re in "${SOPS_REGEXES[@]}"; do
    if [[ "$path" =~ $re ]]; then sops_managed=1; break; fi
  done
  if [ "$sops_managed" = 1 ]; then
    # filestatus reads a path, so check the staged blob, not the worktree file
    status=$(git show ":$path" | sops filestatus --input-type json /dev/stdin 2>/dev/null | jq -r '.encrypted // false')
    if [ "$status" != true ]; then
      echo "ERROR: $path is staged unencrypted; encrypt it with src/scripts/sops-encrypt.sh" >&2
      problems=$((problems + 1))
    fi
    continue
  fi
  if git show ":$path" | grep -aqE "$SECRET_PATTERNS"; then
    echo "ERROR: $path contains private key material" >&2
    problems=$((problems + 1))
  fi
done < <(git diff --cached --name-only -z --diff-filter=ACMR)

[ "$problems" = 0 ] || { echo "ERROR: $problems staged file(s) would publish secrets; nothing committed." >&2; exit 1; }
