#!/usr/bin/env bash
# Prints an installation token (valid 1 h) of a GitHub App for one repository,
# scoped to that repository. Used by Hermes (lab-github-token on vm-113) and by
# hermes-secrets.sh to check the app is installed.
#
#   github-app-token.sh <app id> <private key file> [owner/repo]
set -euo pipefail

app_id=${1:?usage: github-app-token.sh <app id> <private key file> [owner/repo]}
key=${2:?private key file}
repo=${3:-lsck0/homelab}
api_url=https://api.github.com

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
api() { # bearer, curl args...
  curl -sf -H "Authorization: Bearer $1" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "${@:2}"
}

# app JWT: GitHub accepts at most 10 minutes; iat is backdated for clock skew
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" -binary | b64url)
jwt="$header.$payload.$signature"

installation=$(api "$jwt" "$api_url/repos/$repo/installation" | jq -r '.id // empty') \
  || { echo "github-app-token: app $app_id is not installed on $repo" >&2; exit 1; }
[ -n "$installation" ] || { echo "github-app-token: app $app_id is not installed on $repo" >&2; exit 1; }

api "$jwt" -X POST "$api_url/app/installations/$installation/access_tokens" \
  -d "$(jq -cn --arg r "${repo#*/}" '{repositories: [$r]}')" | jq -re .token
