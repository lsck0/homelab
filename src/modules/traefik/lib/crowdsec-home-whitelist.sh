#!/usr/bin/env bash
# never let crowdsec ban the house (the lab's own ranges are modules/traefik's static whitelist)
#
# The house is its public v4 address and its v6 prefix, which the router learns and serves to the lab as PUBLIC_HOST
# and PUBLIC_PREFIX_HOST (core/300-router/main.nix public-address, public-prefix); the lab is v4-only, so both are
# read by name. No v4 address: the file stays as it is. No prefix: the file keeps the one it has.
set -euo pipefail

: "${PUBLIC_HOST:?the name the router serves the public address as}"
: "${PUBLIC_PREFIX_HOST:?the name the router serves the public prefix as}"
: "${PUBLIC_PREFIX_LENGTH:?the length of the public prefix}"
CONFIG=${CROWDSEC_CONFIG:-/var/lib/crowdsec/config}
OUT=$CONFIG/parsers/s02-enrich/home-whitelist.yaml
CONTAINER=${CONTAINER:-crowdsec}
# a list item of the yaml below
ITEM_INDENT="    "

if ! resolved=$(getent ahostsv4 "$PUBLIC_HOST"); then
  echo "$PUBLIC_HOST does not resolve yet; leaving the whitelist alone"
  exit 0
fi
v4=$(head -n 1 <<<"$resolved" | cut -d ' ' -f 1)

# getent hosts, not ahostsv6: that one asks no AAAA on a host without ipv6; an A answer has no colon
prefix=""
if resolved=$(getent hosts "$PUBLIC_PREFIX_HOST") && network=$(head -n 1 <<<"$resolved" | cut -d ' ' -f 1) \
  && [[ $network == *:* ]]; then
  prefix=$network/$PUBLIC_PREFIX_LENGTH
elif [ -f "$OUT" ]; then
  prefix=$(sed -n "s|^$ITEM_INDENT- \"\(.*/.*\)\"\$|\1|p" "$OUT")
  echo "$PUBLIC_PREFIX_HOST does not resolve; keeping the prefix ${prefix:-(none)}"
fi

tmp=$(mktemp)
{
  echo "name: homelab/home-whitelist"
  echo "description: \"The addresses the house is seen as. Generated; do not edit.\""
  echo "whitelist:"
  echo "  reason: \"home network\""
  echo "  ip:"
  echo "$ITEM_INDENT- \"$v4\""
  if [ -n "$prefix" ]; then
    echo "  cidr:"
    echo "$ITEM_INDENT- \"$prefix\""
  fi
} > "$tmp"

if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
  rm -f "$tmp"
else
  mkdir -p "$(dirname "$OUT")"
  mv "$tmp" "$OUT"
  chmod 644 "$OUT"
  echo "home whitelist updated: $v4 ${prefix:-(no prefix)}"
  # sighup, not a restart
  podman kill --signal HUP "$CONTAINER" >/dev/null
fi

# lift any existing ban on the house; the whitelist above stops new ones
podman exec "$CONTAINER" cscli decisions delete --ip "$v4" >/dev/null
if [ -n "$prefix" ]; then
  # --contained: the bans inside the prefix; without it only those spanning all of it
  podman exec "$CONTAINER" cscli decisions delete --range "$prefix" --contained >/dev/null
fi
echo "home whitelist in place ($v4 ${prefix:-(no prefix)})"
