#!/usr/bin/env bash
# never let crowdsec ban the house
set -euo pipefail

CONFIG=${CROWDSEC_CONFIG:-/var/lib/crowdsec/config}
OUT=$CONFIG/parsers/s02-enrich/home-whitelist.yaml
CONTAINER=${CONTAINER:-crowdsec}
# ipify splits v4 and v6 across hostnames
V4_URL=${V4_URL:-https://api.ipify.org}
V6_URL=${V6_URL:-https://api6.ipify.org}
# lab is ipv4-only, so the v6 prefix is static
HOME_V6=${HOME_V6:-2003:f7:8f00::/40}

v4=$(curl -sf -4 -m 20 "$V4_URL" || true)
v6=$(curl -sf -6 -m 20 "$V6_URL" || true)

# no v4: keep the file, never lock out the house
if [ -z "$v4" ]; then
  echo "could not resolve the public address; leaving the whitelist alone"
  exit 1
fi

# /48 not the address: telekom rotates the prefix
v6_prefix=$HOME_V6
if [ -n "$v6" ]; then
  v6_prefix=$(echo "$v6" | awk -F: '{printf "%s:%s:%s::/48", $1, $2, $3}')
fi

tmp=$(mktemp)
{
  echo "name: homelab/home-whitelist"
  echo "description: \"The address the house is seen as. Generated; do not edit.\""
  echo "whitelist:"
  echo "  reason: \"home network\""
  if [ -n "$v4" ]; then
    echo "  ip:"
    echo "    - \"$v4\""
  fi
  echo "  cidr:"
  # lab networks reach traefik via the relay
  echo "    - \"10.0.0.0/8\""
  echo "    - \"172.16.0.0/12\""
  echo "    - \"192.168.0.0/16\""
  [ -n "$v6_prefix" ] && echo "    - \"$v6_prefix\""
} > "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
else
  mkdir -p "$(dirname "$OUT")"
  mv "$tmp" "$OUT"
  chmod 644 "$OUT"
  echo "home whitelist updated: ${v4:-no v4} ${v6_prefix:-no v6}"
  # sighup, not a restart
  podman kill --signal HUP "$CONTAINER" >/dev/null 2>&1 || true
fi

# also lift any existing ban on the house
if [ -n "$v4" ]; then
  podman exec "$CONTAINER" cscli decisions delete --ip "$v4" >/dev/null 2>&1 || true
fi
podman exec "$CONTAINER" cscli decisions delete --range "$v6_prefix" >/dev/null 2>&1 || true
echo "home whitelist in place (${v4:-no v4}, $v6_prefix)"
