#!/usr/bin/env bash
# pull-mirror every owned github repo into forgejo
set -euo pipefail

FORGEJO_URL=${FORGEJO_URL:?the forgejo base url}
FORGEJO_OWNER=${FORGEJO_OWNER:?the Forgejo user the mirrors belong to}
MIRROR_INTERVAL=${MIRROR_INTERVAL:?forgejo re-fetch interval, e.g. 8h}

FORGEJO_TOKEN=$(cat "${FORGEJO_TOKEN_FILE:?}")
GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_FILE:?}")
[ -n "$FORGEJO_TOKEN" ] || { echo "ERROR: Forgejo token is empty"; exit 1; }
[ -n "$GITHUB_TOKEN" ] || { echo "ERROR: GitHub token is empty"; exit 1; }

problems=0
later() { echo "$*"; problems=$((problems + 1)); }

# forgejo reports "8h" back as "8h0m0s"
dur_seconds() {
  echo "$1" | awk '{
    s = 0; t = $0
    while (match(t, /^[0-9]+[hms]/)) {
      v = substr(t, RSTART, RLENGTH)
      n = substr(v, 1, length(v) - 1); u = substr(v, length(v))
      s += n * (u == "h" ? 3600 : (u == "m" ? 60 : 1))
      t = substr(t, RSTART + RLENGTH)
    }
    print s
  }'
}

fj() {
  local method=$1 path=$2
  shift 2
  curl -fsS -X "$method" "$FORGEJO_URL/api/v1$path" \
    -H "Authorization: token $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" "$@"
}

gh_api() {
  curl -fsS "https://api.github.com$1" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28"
}

# every repository the token's account owns, private ones included
repos=$(
  page=1
  while :; do
    body=$(gh_api "/user/repos?affiliation=owner&per_page=100&page=$page")
    count=$(echo "$body" | jq 'length')
    [ "$count" -gt 0 ] || break
    echo "$body" | jq -c '.[] | {name, private, clone_url, archived, fork}'
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
  done
)
total=$(printf '%s' "$repos" | jq -s length)
[ "$total" -gt 0 ] || { echo "ERROR: GitHub returned no repositories"; exit 1; }
echo "GitHub reports $total repositories owned by the token's account"

created=0 corrected=0 unchanged=0 skipped=0

while read -r repo; do
  [ -n "$repo" ] || continue
  name=$(echo "$repo" | jq -r .name)
  private=$(echo "$repo" | jq -r .private)
  clone=$(echo "$repo" | jq -r .clone_url)

  if existing=$(fj GET "/repos/$FORGEJO_OWNER/$name"); then
    if [ "$(echo "$existing" | jq -r '.mirror')" != "true" ]; then
      # a real repo owns the name; never clobber it
      later "$name: exists in Forgejo and is not a mirror, left alone"
      skipped=$((skipped + 1))
      continue
    fi
    have=$(dur_seconds "$(echo "$existing" | jq -r '.mirror_interval')")
    if [ "$have" = "$(dur_seconds "$MIRROR_INTERVAL")" ]; then
      unchanged=$((unchanged + 1))
    elif fj PATCH "/repos/$FORGEJO_OWNER/$name" \
        -d "$(jq -cn --arg i "$MIRROR_INTERVAL" '{mirror_interval: $i}')" >/dev/null; then
      echo "$name: interval corrected to $MIRROR_INTERVAL"
      corrected=$((corrected + 1))
    else
      later "$name: could not correct the interval"
      continue
    fi
  else
    # only private repos get the token
    body=$(jq -cn \
      --arg addr "$clone" --arg name "$name" --arg owner "$FORGEJO_OWNER" \
      --arg interval "$MIRROR_INTERVAL" --arg tok "$GITHUB_TOKEN" \
      --argjson private "$private" '
      {
        clone_addr: $addr, repo_name: $name, repo_owner: $owner,
        service: "github", mirror: true, mirror_interval: $interval,
        private: $private,
        # copied once; github has no incremental feed
        issues: true, labels: true, milestones: true, releases: true, wiki: true
      } + (if $private then {auth_token: $tok} else {} end)')
    if fj POST "/repos/migrate" -d "$body" >/dev/null; then
      echo "$name: mirror created"
      created=$((created + 1))
      # the migration clones at once
      continue
    fi
    later "$name: migration failed"
    continue
  fi

  # a mirror is only as good as its last fetch
  fj POST "/repos/$FORGEJO_OWNER/$name/mirror-sync" >/dev/null \
    || later "$name: sync request failed"
done <<< "$repos"

echo "created=$created corrected=$corrected unchanged=$unchanged skipped=$skipped"
if [ "$problems" -gt 0 ]; then
  echo "$problems repositories need attention"
  exit 1
fi
echo "every GitHub repository is mirrored"
