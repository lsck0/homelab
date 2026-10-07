#!/usr/bin/env bash
# point the lab's cloudflare A records at the house's public address
#
# Run by the router's ddns-cloudflare timer (instances/300-router/main.nix), which generates the record list from the
# route catalog. A record's state is converged, never assumed: a missing record is created, a wrong address or
# proxy flag is put right, and duplicates of one name (a past run that created a second record) are deleted down to
# one. The address is recorded as synced only when every record converged, so a failed call is retried by the next
# run; while the address is unchanged and synced within DDNS_RESYNC_MIN, cloudflare is not asked at all.
#
# Environment (defaults in brackets):
#   DDNS_RECORDS      json file: [{ "name": "grafana.lsck0.dev", "proxied": true }, ...]
#   DDNS_ZONE         the cloudflare zone, e.g. lsck0.dev
#   DDNS_TOKEN_FILE   file holding the api token (zone dns edit)
#   DDNS_STATE_DIR    where the last synced address is kept
#   DDNS_IP_URL       [https://api.ipify.org] answers the caller's public address as text
#   DDNS_API_URL      [https://api.cloudflare.com/client/v4]
#   DDNS_RESYNC_MIN   [60] minutes after which an unchanged address is checked against cloudflare anyway
#
# The token reaches curl in a header file, never on a command line.
set -euo pipefail
# record names contain "*" (the wildcard), which must never glob
set -f

: "${DDNS_RECORDS:?a json list of records}" "${DDNS_ZONE:?the cloudflare zone}" "${DDNS_TOKEN_FILE:?the api token file}"
: "${DDNS_STATE_DIR:?a state directory}"
DDNS_IP_URL=${DDNS_IP_URL:-https://api.ipify.org}
DDNS_API_URL=${DDNS_API_URL:-https://api.cloudflare.com/client/v4}
DDNS_RESYNC_MIN=${DDNS_RESYNC_MIN:-60}
# cloudflare answers within a few seconds; a hung call must not hold the timer's next run
CURL_TIMEOUT_S=20
# 1: cloudflare's "automatic" ttl
RECORD_TTL=1

LAST="$DDNS_STATE_DIR/ip"

ip=$(curl -sSf --max-time "$CURL_TIMEOUT_S" "$DDNS_IP_URL")
if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ddns: $DDNS_IP_URL answered no ipv4 address: '$ip'" >&2
    exit 1
fi

if [ -f "$LAST" ] && [ "$(cat "$LAST")" = "$ip" ] && [ -n "$(find "$LAST" -mmin "-$DDNS_RESYNC_MIN")" ]; then
    exit 0
fi

header=$(mktemp)
trap 'rm -f "$header"' EXIT
chmod 600 "$header"
printf 'Authorization: Bearer %s\n' "$(cat "$DDNS_TOKEN_FILE")" > "$header"

# one api call; prints the body, fails unless http and cloudflare's own `success` both say ok
api() {
    local body
    body=$(curl -sS --fail-with-body --max-time "$CURL_TIMEOUT_S" -H @"$header" -H 'Content-Type: application/json' "$@") || {
        echo "ddns: $* failed: $body" >&2
        return 1
    }
    jq -e '.success == true' >/dev/null <<<"$body" || {
        echo "ddns: $* answered unsuccessfully: $body" >&2
        return 1
    }
    printf '%s' "$body"
}

zone_id=$(api -G --data-urlencode "name=$DDNS_ZONE" "$DDNS_API_URL/zones" \
    | jq -er '.result | if length == 1 then .[0].id else error("not exactly one zone") end') || {
    echo "ddns: no zone id for $DDNS_ZONE" >&2
    exit 1
}
records_url="$DDNS_API_URL/zones/$zone_id/dns_records"

# converge one name to a single record holding $ip with the given proxy flag
record_sync() {
    local name=$1 proxied=$2 found count first data
    found=$(api -G --data-urlencode "name=$name" --data-urlencode "type=A" "$records_url") || return 1
    count=$(jq '.result | length' <<<"$found")
    data=$(jq -cn --arg name "$name" --arg ip "$ip" --argjson proxied "$proxied" --argjson ttl "$RECORD_TTL" \
        '{type: "A", name: $name, content: $ip, ttl: $ttl, proxied: $proxied}')
    if [ "$count" -eq 0 ]; then
        api -X POST --data "$data" "$records_url" >/dev/null || return 1
        echo "ddns: created $name -> $ip (proxied: $proxied)"
        return 0
    fi
    first=$(jq -c '.result[0]' <<<"$found")
    if [ "$(jq -r '.content' <<<"$first")" != "$ip" ] || [ "$(jq -r '.proxied' <<<"$first")" != "$proxied" ]; then
        api -X PUT --data "$data" "$records_url/$(jq -r '.id' <<<"$first")" >/dev/null || return 1
        echo "ddns: updated $name: $(jq -r '.content' <<<"$first") -> $ip (proxied: $proxied)"
    fi
    # a duplicate splits resolution between a live and a dead address
    local id
    for id in $(jq -r '.result[1:][].id' <<<"$found"); do
        api -X DELETE "$records_url/$id" >/dev/null || return 1
        echo "ddns: deleted duplicate record $id of $name"
    done
}

failures=0
while IFS=$'\t' read -r name proxied; do
    record_sync "$name" "$proxied" || failures=$((failures + 1))
done < <(jq -r '.[] | [.name, (.proxied | tostring)] | @tsv' "$DDNS_RECORDS")

if [ "$failures" -ne 0 ]; then
    echo "ddns: $failures record(s) not converged, $ip stays unsynced for the next run" >&2
    exit 1
fi
printf '%s' "$ip" > "$LAST.tmp"
mv "$LAST.tmp" "$LAST"
