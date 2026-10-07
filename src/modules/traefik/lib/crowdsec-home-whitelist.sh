#!/usr/bin/env bash
# never let crowdsec ban the house (the lab's own ranges are modules/traefik's static whitelist)
#
# The house is its public v4 address and its delegated v6 prefix. Telekom delegates a /56 to one customer and rotates
# it, so the prefix is derived from the address the house is seen with, never a wider static range: a /40 or /48
# covers other customers, whom the edge would then never ban. The lab is v4-only; without a v6 address seen (or
# HOME_V6, the exact delegated prefix, set by hand) no v6 range is whitelisted.
set -euo pipefail

CONFIG=${CROWDSEC_CONFIG:-/var/lib/crowdsec/config}
OUT=$CONFIG/parsers/s02-enrich/home-whitelist.yaml
CONTAINER=${CONTAINER:-crowdsec}
# ipify splits v4 and v6 across hostnames
V4_URL=${V4_URL:-https://api.ipify.org}
V6_URL=${V6_URL:-https://api6.ipify.org}
HOME_V6=${HOME_V6:-}
# the prefix length one telekom customer is delegated
DELEGATED_V6_PREFIX_LENGTH=56
LOOKUP_TIMEOUT_S=20

v4=$(curl -sf -4 -m "$LOOKUP_TIMEOUT_S" "$V4_URL") || v4=""
# no v6 route is the usual case, the lab is v4-only
v6=$(curl -sf -6 -m "$LOOKUP_TIMEOUT_S" "$V6_URL") || v6=""

# no v4: keep the file, never lock out the house
if [ -z "$v4" ]; then
  echo "could not resolve the public address; leaving the whitelist alone"
  exit 1
fi

# the /56 holding the address: the first three hextets and the top byte of the fourth
v6_prefix=$HOME_V6
if [ -z "$v6_prefix" ] && [ -n "$v6" ]; then
  v6_prefix=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False))' \
    "$v6" "$DELEGATED_V6_PREFIX_LENGTH")
fi

tmp=$(mktemp)
{
  echo "name: homelab/home-whitelist"
  echo "description: \"The address the house is seen as. Generated; do not edit.\""
  echo "whitelist:"
  echo "  reason: \"home network\""
  echo "  ip:"
  echo "    - \"$v4\""
  if [ -n "$v6_prefix" ]; then printf '  cidr:\n    - "%s"\n' "$v6_prefix"; fi
} > "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
else
  mkdir -p "$(dirname "$OUT")"
  mv "$tmp" "$OUT"
  chmod 644 "$OUT"
  echo "home whitelist updated: $v4 ${v6_prefix:-no v6}"
  # sighup, not a restart; a crowdsec still starting reads the new file anyway
  podman kill --signal HUP "$CONTAINER" >/dev/null 2>&1 || true
fi

# lift any existing ban on the house; best effort, the whitelist above already stops new ones
podman exec "$CONTAINER" cscli decisions delete --ip "$v4" >/dev/null 2>&1 || true
if [ -n "$v6_prefix" ]; then
  podman exec "$CONTAINER" cscli decisions delete --range "$v6_prefix" >/dev/null 2>&1 || true
fi
echo "home whitelist in place ($v4, ${v6_prefix:-no v6})"
