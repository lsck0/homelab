#!/usr/bin/env bash
# never let crowdsec ban the house (the lab's own ranges are modules/traefik's static whitelist)
#
# The house is its public v4 address, which the router learns and serves to the lab as PUBLIC_HOST
# (instances/300-router/main.nix public-address); the lab is v4-only. Nothing resolved: the file stays as it is.
set -euo pipefail

: "${PUBLIC_HOST:?the name the router serves the public address as}"
CONFIG=${CROWDSEC_CONFIG:-/var/lib/crowdsec/config}
OUT=$CONFIG/parsers/s02-enrich/home-whitelist.yaml
CONTAINER=${CONTAINER:-crowdsec}

if ! resolved=$(getent ahostsv4 "$PUBLIC_HOST"); then
  echo "$PUBLIC_HOST does not resolve yet; leaving the whitelist alone"
  exit 0
fi
v4=$(head -n 1 <<<"$resolved" | cut -d ' ' -f 1)

tmp=$(mktemp)
{
  echo "name: homelab/home-whitelist"
  echo "description: \"The address the house is seen as. Generated; do not edit.\""
  echo "whitelist:"
  echo "  reason: \"home network\""
  echo "  ip:"
  echo "    - \"$v4\""
} > "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
else
  mkdir -p "$(dirname "$OUT")"
  mv "$tmp" "$OUT"
  chmod 644 "$OUT"
  echo "home whitelist updated: $v4"
  # sighup, not a restart
  podman kill --signal HUP "$CONTAINER" >/dev/null
fi

# lift any existing ban on the house; the whitelist above stops new ones
podman exec "$CONTAINER" cscli decisions delete --ip "$v4" >/dev/null
echo "home whitelist in place ($v4)"
