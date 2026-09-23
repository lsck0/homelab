#!/usr/bin/env bash
# Never let CrowdSec ban the house.
#
# It did. A burst of requests across a dozen hosts looked like
# crowdsecurity/http-crawl-non_statics, and every service in the lab answered
# 403 from the outside until the decision was deleted by hand.
#
# There was a whitelist, and it was the problem: a hardcoded IPv6 prefix.
# Telekom rotated the delegation from 2003:f7:8f3a::/48 to 2003:f7:8f43::/48
# and the whitelist silently stopped matching anything. An address that
# changes cannot be pinned in a config file, so it is asked for instead.
#
# Whitelisting in CrowdSec rather than only in the Traefik bouncer, because
# this stops the decision being taken at all rather than stopping one bouncer
# from acting on it.
set -euo pipefail

CONFIG=${CROWDSEC_CONFIG:-/var/lib/crowdsec/config}
OUT=$CONFIG/parsers/s02-enrich/home-whitelist.yaml
CONTAINER=${CONTAINER:-crowdsec}
# ipify answers over v4 and v6 on separate names, so each family is resolved
# on its own rather than whichever the resolver happened to prefer.
V4_URL=${V4_URL:-https://api.ipify.org}
V6_URL=${V6_URL:-https://api6.ipify.org}
# The lab is IPv4-only, so this VM cannot ask what the house's IPv6 is - it has
# no route to find out. The delegation still has to be whitelisted, because
# that is the address a browser at home actually arrives from and the one that
# got banned. So it is declared rather than discovered, and deliberately as a
# /40: Telekom has moved this house between 2003:f7:8f3a::/48 and
# 2003:f7:8f43::/48, both inside 2003:f7:8f00::/40, so the wider block survives
# a rotation that a /48 does not. It whitelists other Telekom customers too.
# That is the trade: failing to ban one of them costs a great deal less than
# locking the owner out of every service, which is what the /48 did.
HOME_V6=${HOME_V6:-2003:f7:8f00::/40}

v4=$(curl -sf -4 -m 20 "$V4_URL" || true)
v6=$(curl -sf -6 -m 20 "$V6_URL" || true)

# A run that resolves no v4 must not rewrite the file: a whitelist that lost
# the house is how the house gets locked out, which is the thing this exists
# to prevent. The v6 block is declared, so its absence is not a failure.
if [ -z "$v4" ]; then
  echo "could not resolve the public address; leaving the whitelist alone"
  exit 1
fi

# The /48 rather than the address: Telekom hands out a /56 and moves it, so
# pinning the exact address would need this to run more often than the
# rotation, and losing that race is another lockout.
# A discovered address wins when there is one; otherwise the declared block.
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
  # the lab's own networks, which reach the external Traefik through the
  # relay and would otherwise be able to ban themselves too
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
  # SIGHUP, not a restart. This used to `podman restart crowdsec`, and
  # restarting it mid-start left the container wedged in Stopping - with the
  # bouncer failing closed, every service in the lab answered 403 until it was
  # forced back up by hand. The whole point of this script is to stop the lab
  # locking its owner out, so it must not be the thing that does it.
  podman kill --signal HUP "$CONTAINER" >/dev/null 2>&1 || true
fi

# The belt to that brace, and the part that matters between reloads: whatever
# CrowdSec has already decided about the house is removed on every run. A
# parser only takes effect for events it has yet to see; a decision taken a
# minute ago is still in the database and the bouncer still acts on it.
if [ -n "$v4" ]; then
  podman exec "$CONTAINER" cscli decisions delete --ip "$v4" >/dev/null 2>&1 || true
fi
podman exec "$CONTAINER" cscli decisions delete --range "$v6_prefix" >/dev/null 2>&1 || true
echo "home whitelist in place (${v4:-no v4}, $v6_prefix)"
